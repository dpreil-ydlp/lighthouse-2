import Foundation
import Testing
@testable import LighthouseCore

// MARK: Test doubles

/// Scripted transport: returns queued outcomes in order and records every request it saw.
final class ScriptedTransport: UsageTransport, @unchecked Sendable {
    enum Outcome { case response(Int, String, TimeInterval?), error(UsageTransportError) }
    private let lock = NSLock()
    private var queue: [Outcome]
    private(set) var requests: [UsageRequest] = []

    init(_ outcomes: [Outcome] = []) { queue = outcomes }

    func push(_ outcome: Outcome) { lock.withLock { queue.append(outcome) } }

    func get(_ request: UsageRequest) async throws(UsageTransportError) -> UsageHTTPResponse {
        let next: Outcome = lock.withLock {
            requests.append(request)
            return queue.isEmpty ? .error(.offline) : queue.removeFirst()
        }
        switch next {
        case .response(let status, let body, let retry): return UsageHTTPResponse(status: status, body: Data(body.utf8), retryAfter: retry)
        case .error(let error): throw error
        }
    }
}

final class FakeCredentials: UsageCredentialSource, @unchecked Sendable {
    private let lock = NSLock()
    var result: CredentialResult
    let mayPrompt: Bool
    private(set) var loads = 0
    var location: String { mayPrompt ? "Keychain · test" : "test file" }

    init(_ result: CredentialResult, mayPrompt: Bool = false) {
        self.result = result
        self.mayPrompt = mayPrompt
    }

    func set(_ result: CredentialResult) { lock.withLock { self.result = result } }

    /// The account a non-prompting identity source reports (Claude `~/.claude.json`); nil = none.
    var account: String?
    private(set) var identityReads = 0
    func setAccount(_ id: String?) { lock.withLock { account = id } }
    func currentAccountId() -> String? {
        lock.withLock {
            identityReads += 1
            return account
        }
    }

    func load() -> CredentialResult {
        lock.withLock {
            loads += 1
            return result
        }
    }
}

enum UsageFixture {
    static let t0 = Fixture.date("2026-10-29T12:00:00.000Z")
    static let token = Fixture.secretCanary

    static func credential(account: String? = "acct-1111", expires: Date? = nil, token: String = token) -> CredentialResult {
        .found(UsageCredential(accessToken: token, accountId: account, plan: "max", expiresAt: expires))
    }

    static func claude(session: Double, sessionReset: String = "2026-10-29T14:10:00.000000+00:00",
                       weekly: Double? = 63, weeklyReset: String = "2026-10-30T09:00:00+00:00") -> String {
        let week = weekly.map { #"{"utilization":\#($0),"resets_at":"\#(weeklyReset)"}"# } ?? "null"
        return #"{"five_hour":{"utilization":\#(session),"resets_at":"\#(sessionReset)"},"seven_day":\#(week),"seven_day_opus":null,"seven_day_sonnet":{"utilization":12.0,"resets_at":null},"extra_usage":{"is_enabled":false}}"#
    }

    static func codex(primary: Int, primaryReset: Double = t0.timeIntervalSince1970 + 3600, secondary: Int? = 34,
                      account: String = "acct-codex-9a8b") -> String {
        let second = secondary.map { #"{"used_percent":\#($0),"limit_window_seconds":604800,"reset_after_seconds":86400,"reset_at":\#(Int(t0.timeIntervalSince1970) + 86400)}"# } ?? "null"
        return #"{"account_id":"\#(account)","plan_type":"plus","rate_limit":{"allowed":true,"limit_reached":false,"primary_window":{"used_percent":\#(primary),"limit_window_seconds":18000,"reset_after_seconds":3600,"reset_at":\#(Int(primaryReset))},"secondary_window":\#(second)},"credits":{"has_credits":false},"additional_rate_limits":[{"limit_name":"Example-Pool","rate_limit":{"primary_window":{"used_percent":9,"limit_window_seconds":18000,"reset_at":\#(Int(t0.timeIntervalSince1970) + 7200)},"secondary_window":null}}]}"#
    }

    static func monitor(_ provider: Provider, credentials: FakeCredentials, transport: ScriptedTransport) -> UsageMonitor {
        let adapter: any UsageAdapter = provider == .claude ? ClaudeUsageAdapter() : CodexUsageAdapter()
        return UsageMonitor(providers: [provider: .init(adapter: adapter, credentials: credentials)], transport: transport)
    }
}

/// Every text form a reading can take: description, debug description, and a full dump.
func renderings(_ value: Any) -> String {
    var dumped = ""
    dump(value, to: &dumped)
    return "\(value)\n\(String(reflecting: value))\n\(dumped)"
}

// MARK: Adapters

@Suite struct UsageAdapterTests {
    let now = UsageFixture.t0
    let credential = UsageCredential(accessToken: Fixture.secretCanary, accountId: "acct-1111", plan: "max", expiresAt: nil)

    @Test func claudeParsesSessionWeeklyAndPools() throws {
        let sample = try ClaudeUsageAdapter().parse(Data(UsageFixture.claude(session: 41).utf8), credential: credential, now: now)
        #expect(sample.windows.map(\.id) == ["session", "weekly", "sonnet-week"])
        let session = sample.windows[0]
        #expect(session.usedPercent == 41)
        #expect(session.duration == TimeInterval(5 * 3600))
        #expect(session.resetsAt == Fixture.date("2026-10-29T14:10:00.000Z"))
        #expect(sample.windows[1].usedPercent == 63)
        #expect(sample.windows[2].resetsAt == nil)
        #expect(sample.accountId == "acct-1111")
        #expect(sample.plan == "max")
    }

    @Test func codexParsesPrimarySecondaryAndNamedPools() throws {
        let sample = try CodexUsageAdapter().parse(Data(UsageFixture.codex(primary: 88).utf8), credential: credential, now: now)
        #expect(sample.windows.map(\.id) == ["session", "weekly", "Example-Pool-session"])
        #expect(sample.windows[0].usedPercent == 88)
        #expect(sample.windows[0].resetsAt == now.addingTimeInterval(3600))
        #expect(sample.windows[1].duration == 604800)
        #expect(sample.windows[2].label == "Example-Pool · session")
        #expect(sample.accountId == "acct-1111", "the credential's account wins")
        #expect(sample.plan == "plus")
    }

    @Test func requestsGoOnlyToTheAllowlistedEndpointsWithTheTokenInTheHeaderOnly() {
        let claude = ClaudeUsageAdapter().request(for: credential)
        let codex = CodexUsageAdapter().request(for: credential)
        #expect(claude.url.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        #expect(codex.url.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
        #expect(claude.header("Authorization") == "Bearer \(Fixture.secretCanary)")
        #expect(claude.header("anthropic-beta") == "oauth-2025-04-20")
        #expect(codex.header("ChatGPT-Account-Id") == "acct-1111")
        for request in [claude, codex] {
            #expect(!request.url.absoluteString.contains(Fixture.secretCanary))
            #expect(!renderings(request).contains(Fixture.secretCanary))
        }
    }

    @Test func credentialNeverRendersItsToken() {
        #expect(!renderings(credential).contains(Fixture.secretCanary))
        #expect(!renderings(CredentialResult.found(credential)).contains(Fixture.secretCanary))
    }

    @Test func codexAuthFileParsing() {
        // exp = 2026-10-29T13:00:00Z in a fake JWT.
        let payload = Data(#"{"exp":1793278800}"#.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let jwt = "eyJhbGciOiJub25lIn0.\(payload).sig"
        guard case .found(let c) = CodexAuthFile.parse(Data(#"{"OPENAI_API_KEY":null,"tokens":{"access_token":"\#(jwt)","account_id":"acct-x","refresh_token":"\#(Fixture.secretCanary)"}}"#.utf8)) else {
            Issue.record("expected credential"); return
        }
        #expect(c.accountId == "acct-x")
        #expect(c.expiresAt == Date(timeIntervalSince1970: 1793278800))
        #expect(!renderings(c).contains(Fixture.secretCanary))
        if case .missing = CodexAuthFile.parse(Data(#"{"OPENAI_API_KEY":"sk-x","tokens":null}"#.utf8)) {} else { Issue.record("API-key auth is not a usage credential") }
        if case .unreadable = CodexAuthFile.parse(Data("{not json".utf8)) {} else { Issue.record("malformed auth.json") }
    }

    @Test func codexAuthFileIsReadInPlaceThroughTheBoundary() {
        let s = Scratch()
        s.write("codex/auth.json", #"{"tokens":{"access_token":"\#(Fixture.secretCanary)","account_id":"acct-y"}}"#)
        let access = RecordingAccess()
        guard case .found(let c) = CodexAuthFile(codexHome: s.codexHome, access: access).load() else { Issue.record("expected credential"); return }
        #expect(c.accountId == "acct-y")
        #expect(Set(access.operations.map(\.op)).isSubset(of: ["stat", "read"]))
        // A symlinked auth.json is not followed.
        let link = Scratch()
        link.dir("codex")
        try? FileManager.default.createSymbolicLink(atPath: link.codexHome + "/auth.json", withDestinationPath: s.codexHome + "/auth.json")
        if case .missing = CodexAuthFile(codexHome: link.codexHome).load() {} else { Issue.record("symlinked auth.json was read") }
    }

    @Test func claudeCredentialParsing() {
        let item = Data(#"{"claudeAiOauth":{"accessToken":"\#(Fixture.secretCanary)","refreshToken":"r","expiresAt":1793278800000,"scopes":["user:inference"],"subscriptionType":"max"}}"#.utf8)
        guard case .found(let c) = ClaudeCredentialParser.parse(item, accountId: "uuid-1") else { Issue.record("expected credential"); return }
        #expect(c.plan == "max")
        #expect(c.accountId == "uuid-1")
        #expect(c.expiresAt == Date(timeIntervalSince1970: 1793278800))
        if case .missing = ClaudeCredentialParser.parse(Data(#"{"other":{}}"#.utf8), accountId: nil) {} else { Issue.record("missing oauth") }
        if case .unreadable = ClaudeCredentialParser.parse(Data("garbage".utf8), accountId: nil) {} else { Issue.record("garbage") }

        let s = Scratch()
        let path = s.write("claude.json", #"{"projects":{"/x":{"history":["\#(Fixture.bodyCanary)"]}},"oauthAccount":{"accountUuid":"uuid-2","emailAddress":"me@example.com"}}"#)
        #expect(ClaudeCredentialParser.accountId(claudeJSON: path) == "uuid-2")
    }

    @Test func transportRefusesAnyOtherURLBeforeConnecting() async {
        let transport = HTTPSUsageTransport()
        for url in ["https://example.com/api/oauth/usage", "http://api.anthropic.com/api/oauth/usage",
                    "https://api.anthropic.com/api/oauth/usage?x=1", "https://chatgpt.com/backend-api/wham/usage/../x"] {
            do {
                _ = try await transport.get(UsageRequest(url: URL(string: url)!, headers: [:]))
                Issue.record("\(url) was allowed")
            } catch {
                #expect(error == .blocked)
            }
        }
    }

    @Test func planAndWindowWording() {
        #expect(UsageText.plan("max") == "Max")
        #expect(UsageText.plan("default_claude_max_20x") == "Max 20x")
        #expect(UsageText.plan(nil) == nil)
        #expect(CodexUsageAdapter.kind(18000).id == "session")
        #expect(CodexUsageAdapter.kind(604800).id == "weekly")
        #expect(CodexUsageAdapter.kind(nil).id == "session")
    }
}

// MARK: SPEC §11 M2 (2), (3), (5)

@Suite struct UsageMonitorTests {
    let t0 = UsageFixture.t0

    @Test func freshReadingFromBothProviders() async {
        let claude = UsageFixture.monitor(.claude, credentials: FakeCredentials(UsageFixture.credential(), mayPrompt: true),
                                          transport: ScriptedTransport([.response(200, UsageFixture.claude(session: 41), nil)]))
        let reading = await claude.poll(.claude, now: t0)!
        #expect(reading.status == .fresh)
        #expect(reading.session?.usedPercent == 41)
        #expect(reading.weekly?.usedPercent == 63)
        #expect(reading.accountAlias == "Account ••1111")
        #expect(reading.lastSuccessAt == t0)
        #expect(reading.source == "Keychain · test → api.anthropic.com")

        let codex = UsageFixture.monitor(.codex, credentials: FakeCredentials(UsageFixture.credential()),
                                         transport: ScriptedTransport([.response(200, UsageFixture.codex(primary: 88), nil)]))
        let c = await codex.poll(.codex, now: t0)!
        #expect(c.status == .fresh)
        #expect(c.session?.usedPercent == 88)
        #expect(c.plan == "plus")
        #expect(c.accountAlias == "Account ••1111")
    }

    /// (2) missing weekly window: the row is omitted, never shown as 0 %.
    @Test func missingWeeklyWindowIsOmitted() async {
        let claude = UsageFixture.monitor(.claude, credentials: FakeCredentials(UsageFixture.credential()),
                                          transport: ScriptedTransport([.response(200, UsageFixture.claude(session: 41, weekly: nil), nil)]))
        let r = await claude.poll(.claude, now: t0)!
        #expect(r.weekly == nil)
        #expect(r.displayWindows(now: t0).map(\.id) == ["session", "sonnet-week"])
        let codex = UsageFixture.monitor(.codex, credentials: FakeCredentials(UsageFixture.credential()),
                                         transport: ScriptedTransport([.response(200, UsageFixture.codex(primary: 20, secondary: nil), nil)]))
        let c = await codex.poll(.codex, now: t0)!
        #expect(c.weekly == nil)
        #expect(!c.displayWindows(now: t0).contains { $0.id == "weekly" })
        #expect(!c.windows.contains { $0.usedPercent == 0 })
    }

    /// (2) reset: after the reset time the old percent is no longer drawn or counted as near limit;
    /// the next success shows the new window.
    @Test func windowResetHidesTheOldPercentUntilTheNextReading() async {
        let transport = ScriptedTransport([.response(200, UsageFixture.codex(primary: 92, primaryReset: t0.timeIntervalSince1970 + 60), nil)])
        let monitor = UsageFixture.monitor(.codex, credentials: FakeCredentials(UsageFixture.credential()), transport: transport)
        let before = await monitor.poll(.codex, now: t0)!
        #expect(UsageGlyphState(readings: [before], now: t0).nearLimit == .amber)
        let afterReset = t0.addingTimeInterval(90)
        #expect(!before.displayWindows(now: afterReset).contains { $0.id == "session" })
        #expect(UsageGlyphState(readings: [before], now: afterReset).nearLimit == .none)
        transport.push(.response(200, UsageFixture.codex(primary: 3, primaryReset: t0.timeIntervalSince1970 + 60 + 18000), nil))
        let next = await monitor.poll(.codex, now: afterReset)!
        #expect(next.session?.usedPercent == 3)
        #expect(next.displayWindows(now: afterReset).first?.id == "session")
    }

    /// (2) account switch resets the provider's readings, even when the new account's first
    /// attempt fails: the old account's numbers are never shown for the new one.
    @Test func accountSwitchResetsReadings() async {
        let credentials = FakeCredentials(UsageFixture.credential(account: "acct-AAAA"))
        let transport = ScriptedTransport([.response(200, UsageFixture.codex(primary: 70, account: "acct-AAAA"), nil)])
        let monitor = UsageFixture.monitor(.codex, credentials: credentials, transport: transport)
        let first = await monitor.poll(.codex, now: t0)!
        #expect(first.session?.usedPercent == 70)

        credentials.set(UsageFixture.credential(account: "acct-BBBB"))
        transport.push(.error(.offline))
        let switched = await monitor.poll(.codex, now: t0.addingTimeInterval(120))!
        #expect(switched.accountId == "acct-BBBB")
        #expect(switched.windows.isEmpty)
        #expect(switched.lastSuccessAt == nil)
        #expect(switched.status == .unavailable("Network unavailable"))

        transport.push(.response(200, UsageFixture.codex(primary: 42, account: "acct-BBBB"), nil))
        let fresh = await monitor.poll(.codex, now: t0.addingTimeInterval(240))!
        #expect(fresh.session?.usedPercent == 42)
        #expect(fresh.accountAlias == "Account ••BBBB")

        // The response's account id is used only when auth.json names none.
        let bare = UsageFixture.monitor(.codex, credentials: FakeCredentials(UsageFixture.credential(account: nil)),
                                        transport: ScriptedTransport([.response(200, UsageFixture.codex(primary: 55, account: "acct-CCCC"), nil)]))
        #expect(await bare.poll(.codex, now: t0)!.accountId == "acct-CCCC")
    }

    /// (2) 401/403 → sign-in required, with no bars even when an older reading exists (SPEC §4).
    @Test func rejectedTokenIsSignInRequired() async {
        for code in [401, 403] {
            let transport = ScriptedTransport([.response(200, UsageFixture.claude(session: 41), nil), .response(code, #"{"error":"\#(Fixture.secretCanary)"}"#, nil)])
            let monitor = UsageFixture.monitor(.claude, credentials: FakeCredentials(UsageFixture.credential()), transport: transport)
            _ = await monitor.poll(.claude, now: t0)
            let r = await monitor.poll(.claude, now: t0.addingTimeInterval(120))!
            #expect(r.status == .signInRequired, "status \(code)")
            #expect(r.displayWindows(now: t0.addingTimeInterval(120)).isEmpty)
            #expect(r.lastSuccessAt == t0)
            #expect(UsageGlyphState(readings: [r], now: t0.addingTimeInterval(120)).worstPercent == nil)
        }
    }

    /// No refresh in v2.0: an expired token is sign-in required and no request is sent.
    @Test func expiredTokenIsSignInRequiredWithoutARequest() async {
        let transport = ScriptedTransport([.response(200, UsageFixture.claude(session: 41), nil)])
        let monitor = UsageFixture.monitor(.claude, credentials: FakeCredentials(UsageFixture.credential(expires: t0.addingTimeInterval(-1))), transport: transport)
        let r = await monitor.poll(.claude, now: t0)!
        #expect(r.status == .signInRequired)
        #expect(transport.requests.isEmpty)
    }

    @Test func missingCredentialsIsSignInRequired() async {
        let transport = ScriptedTransport()
        let monitor = UsageFixture.monitor(.codex, credentials: FakeCredentials(.missing), transport: transport)
        #expect(await monitor.poll(.codex, now: t0)!.status == .signInRequired)
        #expect(transport.requests.isEmpty)
    }

    /// (2) malformed JSON → unavailable, never 0 %.
    @Test func malformedResponseIsUnavailable() async {
        for body in ["{not json", "[]", "\"\(Fixture.secretCanary)\"", ""] {
            let monitor = UsageFixture.monitor(.claude, credentials: FakeCredentials(UsageFixture.credential()),
                                               transport: ScriptedTransport([.response(200, body, nil)]))
            let r = await monitor.poll(.claude, now: t0)!
            #expect(r.status == .unavailable("Unexpected response"), "body \(body)")
            #expect(r.windows.isEmpty)
            #expect(r.displayWindows(now: t0).isEmpty)
        }
    }

    /// (2) network off → unavailable, never 0 %.
    @Test func networkOffIsUnavailable() async {
        for (error, reason) in [(UsageTransportError.offline, "Network unavailable"), (.timedOut, "Request timed out"), (.failed, "Network unavailable")] {
            let monitor = UsageFixture.monitor(.codex, credentials: FakeCredentials(UsageFixture.credential()), transport: ScriptedTransport([.error(error)]))
            let r = await monitor.poll(.codex, now: t0)!
            #expect(r.status == .unavailable(reason))
            #expect(r.displayWindows(now: t0).isEmpty)
            #expect(UsageGlyphState(readings: [r], now: t0).worstPercent == nil)
        }
    }

    /// (3) failed attempts move `lastAttemptAt` only; after 3 poll intervals the reading is stale.
    @Test func lastSuccessAgeDoesNotRefreshOnFailedAttempts() async {
        let transport = ScriptedTransport([.response(200, UsageFixture.codex(primary: 50), nil)])
        let monitor = UsageFixture.monitor(.codex, credentials: FakeCredentials(UsageFixture.credential()), transport: transport)
        _ = await monitor.poll(.codex, now: t0)
        for (i, failure) in [ScriptedTransport.Outcome.error(.offline), .response(500, "oops", nil), .response(200, "{bad", nil)].enumerated() {
            transport.push(failure)
            let at = t0.addingTimeInterval(Double(i + 1) * 120)
            let r = await monitor.poll(.codex, now: at)!
            #expect(r.lastSuccessAt == t0)
            #expect(r.lastAttemptAt == at)
        }
        let late = await monitor.readings(now: t0.addingTimeInterval(360)).first!
        #expect(late.status == .stale)
        #expect(late.lastSuccessAt == t0)
        #expect(late.lastFailure == .malformedResponse)
        // Stale readings keep their numbers but never count toward the near-limit mark.
        #expect(UsageGlyphState(readings: [late], now: t0.addingTimeInterval(360)).worstPercent == nil)
        let tracker = await monitor.trackers[.codex]!
        #expect(!tracker.isStale(now: t0.addingTimeInterval(600)))
        #expect(tracker.isStale(now: t0.addingTimeInterval(601)))
    }

    @Test func rateLimitBacksOffWithoutRequests() async {
        let transport = ScriptedTransport([.response(429, "", 120)])
        let monitor = UsageFixture.monitor(.claude, credentials: FakeCredentials(UsageFixture.credential()), transport: transport)
        let r = await monitor.poll(.claude, now: t0)!
        #expect(r.status == .unavailable("Rate limited by provider"))
        _ = await monitor.poll(.claude, now: t0.addingTimeInterval(60))
        #expect(transport.requests.count == 1)
        _ = await monitor.poll(.claude, now: t0.addingTimeInterval(121))
        #expect(transport.requests.count == 2)
    }

    /// The Keychain is read once and then rationed; a denial suspends reads until the owner retries.
    @Test func keychainReadsAreRationedAndADenialSuspends() async {
        let credentials = FakeCredentials(UsageFixture.credential(), mayPrompt: true)
        let transport = ScriptedTransport((0..<4).map { _ in .response(200, UsageFixture.claude(session: 10), nil) })
        let monitor = UsageFixture.monitor(.claude, credentials: credentials, transport: transport)
        for i in 0..<3 { _ = await monitor.poll(.claude, now: t0.addingTimeInterval(Double(i) * 120)) }
        #expect(credentials.loads == 1)

        let denied = FakeCredentials(.denied, mayPrompt: true)
        let m2 = UsageFixture.monitor(.claude, credentials: denied, transport: ScriptedTransport())
        let r = await m2.poll(.claude, now: t0)!
        #expect(r.status == .unavailable("Keychain access denied · Retry in Settings"))
        _ = await m2.poll(.claude, now: t0.addingTimeInterval(3600))
        #expect(denied.loads == 1)
        await m2.retry(.claude)
        _ = await m2.poll(.claude, now: t0.addingTimeInterval(3720))
        #expect(denied.loads == 2)
    }

    @Test func disableClearsTheReading() async {
        let monitor = UsageFixture.monitor(.codex, credentials: FakeCredentials(UsageFixture.credential()),
                                           transport: ScriptedTransport([.response(200, UsageFixture.codex(primary: 50), nil)]))
        _ = await monitor.poll(.codex, now: t0)
        await monitor.disable(.codex)
        let r = await monitor.readings(now: t0).first!
        #expect(r.windows.isEmpty && r.lastSuccessAt == nil)
    }

    @Test func nearLimitLevels() {
        func reading(_ percents: [Double], status: UsageStatus = .fresh) -> ProviderUsage {
            ProviderUsage(provider: .codex, accountId: "a", plan: nil,
                          windows: percents.enumerated().map { UsageWindow(id: $0.offset == 0 ? "session" : "weekly", label: "", duration: nil, usedPercent: $0.element, resetsAt: nil) },
                          lastAttemptAt: t0, lastSuccessAt: t0, lastFailure: nil, status: status, source: "")
        }
        #expect(UsageGlyphState(readings: [reading([79.4, 10])], now: t0).nearLimit == .none)
        #expect(UsageGlyphState(readings: [reading([80, 10])], now: t0).nearLimit == .amber)
        #expect(UsageGlyphState(readings: [reading([41, 96])], now: t0).nearLimit == .red)
        #expect(UsageGlyphState(readings: [reading([41, 96])], now: t0).worstDescription == "Codex week 4 percent left")
        #expect(UsageGlyphState(readings: [reading([99], status: .stale)], now: t0).nearLimit == .none)
    }

    /// (5) the secret canary (used as the token and echoed in error bodies) is absent from every
    /// reading, failure reason, request rendering and the store on every error path.
    @Test func secretCanaryAbsentOnAllErrorPaths() async throws {
        let s = Scratch()
        let store = try Store(url: s.url.appendingPathComponent("AppSupport/Lighthouse/lighthouse.sqlite"))
        try store.saveUsageSettings(UsageSettings(enabled: [.claude, .codex], showWorstPercent: true))
        let echo = #"{"error":{"message":"invalid token \#(Fixture.secretCanary)","type":"\#(Fixture.secretCanary)"}}"#
        let outcomes: [ScriptedTransport.Outcome] = [
            .response(401, echo, nil), .response(403, echo, nil), .response(429, echo, 30), .response(500, echo, nil),
            .response(502, echo, nil), .response(200, echo, nil), .response(200, "{" + Fixture.secretCanary, nil),
            .error(.offline), .error(.timedOut), .error(.blocked), .error(.failed),
        ]
        var texts: [String] = []
        for provider in Provider.allCases {
            for outcome in outcomes {
                let transport = ScriptedTransport([outcome])
                let monitor = UsageFixture.monitor(provider, credentials: FakeCredentials(UsageFixture.credential()), transport: transport)
                let r = await monitor.poll(provider, now: t0)!
                texts.append(renderings(r))
                texts.append(r.lastFailure?.reason ?? "")
                texts += transport.requests.map(renderings)
                texts.append(renderings(await monitor.trackers))
            }
            for result in [CredentialResult.denied, .unreadable, .missing, UsageFixture.credential(expires: t0)] {
                let monitor = UsageFixture.monitor(provider, credentials: FakeCredentials(result, mayPrompt: true), transport: ScriptedTransport())
                texts.append(renderings(await monitor.poll(provider, now: t0)!))
            }
        }
        for text in texts { #expect(!text.contains(Fixture.secretCanary)) }
        #expect(texts.count > 40)
        store.checkpointWAL()
        for name in try FileManager.default.contentsOfDirectory(atPath: store.url.deletingLastPathComponent().path) {
            #expect(!bytesContain(store.url.deletingLastPathComponent().appendingPathComponent(name).path, Fixture.secretCanary))
        }
        #expect(try store.loadUsageSettings() == UsageSettings(enabled: [.claude, .codex], showWorstPercent: true))
    }
}

// MARK: SPEC §11 M2 (4) local tokens

@Suite struct LocalTokenTests {
    let now = Fixture.date("2026-10-29T12:00:00.000Z")

    func line(_ ordinal: Int, _ time: String, total: Int) -> String {
        #"{"timestamp":"2026-10-29T\#(time).000Z","ordinal":\#(ordinal),"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":\#(total)}}}}"# + "\n"
    }

    let meta = #"{"timestamp":"2026-10-29T09:00:00.000Z","ordinal":0,"type":"session_meta","payload":{"id":"tok-1","cwd":"/Users/me/Projects/beta"}}"# + "\n"
    let file = "codex/sessions/2026/10/29/rollout-tok.jsonl"

    func thread(_ result: PassResult) -> SessionThread? { result.threads.first { $0.sessionId == "tok-1" } }

    @Test func sameRecordReadTwiceAddsZero() async {
        let s = Scratch()
        s.write(file, meta + line(1, "10:00:00", total: 1000))
        let collector = CodexCollector(codexHome: s.codexHome, store: MemoryCheckpoints())
        #expect(thread(await collector.pass(now: now, scope: .full))?.tokensTotal == 1000)
        // A second pass over the unchanged file, and the same record appended again, add nothing.
        #expect(thread(await collector.pass(now: now, scope: .full))?.tokensTotal == 1000)
        s.append(file, line(1, "10:00:00", total: 1000))
        let again = thread(await collector.pass(now: now, scope: .full))
        #expect(again?.tokensTotal == 1000)
        #expect(again?.tokenBuckets.total == 1000)
    }

    @Test func differentIndexesSameTotalAddOnceThenExactDelta() async {
        let s = Scratch()
        s.write(file, meta + line(1, "10:00:00", total: 1000) + line(2, "10:01:00", total: 1000))
        let collector = CodexCollector(codexHome: s.codexHome)
        #expect(thread(await collector.pass(now: now, scope: .full))?.tokensTotal == 1000)
        s.append(file, line(3, "10:20:00", total: 1350))
        let t = thread(await collector.pass(now: now, scope: .full))!
        #expect(t.tokensTotal == 1350)
        // The later increase lands in its own time bucket with exactly its delta.
        let late = DateInterval(start: Fixture.date("2026-10-29T10:15:00.000Z"), end: now)
        #expect(t.tokenBuckets.sum(in: late) == 350)
    }

    @Test func counterResetStartsANewEpoch() async {
        let s = Scratch()
        s.write(file, meta + line(1, "10:00:00", total: 5000) + line(2, "10:10:00", total: 300) + line(3, "10:11:00", total: 450))
        let collector = CodexCollector(codexHome: s.codexHome, store: MemoryCheckpoints())
        let t = thread(await collector.pass(now: now, scope: .full))!
        #expect(t.tokensTotal == 5000 + 300 + 150)
        #expect(t.tokenBuckets.sum(in: DateInterval(start: Fixture.date("2026-10-29T10:10:00.000Z"), end: now)) == 450)
    }

    @Test func midFileStartIsABaselineWithPartialCoverage() {
        var state = CodexFileState()
        let stamp = Fixture.date("2026-10-29T11:00:00.000Z")
        CodexCollector.apply(Data(line(7, "11:00:00", total: 9000).utf8), to: &state, fromStart: false)
        #expect(state.tokens == 0)
        #expect(state.tokensPartial)
        CodexCollector.apply(Data(line(8, "11:05:00", total: 9400).utf8), to: &state, fromStart: false)
        #expect(state.tokens == 400)
        #expect(state.tokenBuckets.sum(in: DateInterval(start: stamp, end: now)) == 400)

        let thread = SessionThread(id: "codex:mid", owningApp: .codex, providerIdentities: [ProviderIdentity(provider: .codex, nativeId: "mid")],
                                   cwd: "/Users/me/Projects/beta", state: .idle, sourceReadAt: now, lastActivityAt: now,
                                   tokensTotal: 400, tokenBuckets: state.tokenBuckets, tokensPartial: state.tokensPartial)
        let project = ProjectSummary(identity: ProjectIdentity(root: "/Users/me/Projects/beta", name: "beta", kind: .folder),
                                     threads: [thread], status: .recent, lastActivityAt: now)
        let status = CollectorStatus(source: .codex, lastReadAt: now, threadCount: 1, filesIndexed: 1, filesInWindow: 1, filesNotIndexed: 0, skippedLines: 0)
        let attribution = LocalTokenAttribution(provider: .codex, usage: nil, projects: [project], statuses: [status], now: now)
        #expect(attribution.projects.map(\.tokens) == [400])
        #expect(attribution.partial)
    }

    @Test func claudeCountsEachMessageIdOnceInItsBucket() {
        var state = ClaudeFileState(isChild: false)
        let record = #"{"type":"assistant","sessionId":"c1","cwd":"/x","timestamp":"2026-10-29T11:30:00.000Z","message":{"id":"msg_1","usage":{"input_tokens":10,"output_tokens":5}}}"#
        ClaudeCodeCollector.apply(Data(record.utf8), to: &state)
        ClaudeCodeCollector.apply(Data(record.utf8), to: &state)
        #expect(state.tokens == 15)
        #expect(state.tokenBuckets.total == 15)
    }

    @Test func attributionRanksProjectsInTheProviderSessionWindow() {
        func thread(_ id: String, _ provider: Provider, _ entries: [(String, Int)], children: [Subagent] = []) -> SessionThread {
            var buckets = TokenBuckets()
            for (time, n) in entries { buckets.add(n, at: Fixture.date("2026-10-29T\(time).000Z")) }
            return SessionThread(id: "\(provider.rawValue):\(id)", owningApp: provider == .claude ? .claudeCode : .codex,
                                 providerIdentities: [ProviderIdentity(provider: provider, nativeId: id)], cwd: "/x", state: .idle,
                                 sourceReadAt: now, lastActivityAt: now, tokenBuckets: buckets, subagents: children)
        }
        var childBuckets = TokenBuckets()
        childBuckets.add(700, at: Fixture.date("2026-10-29T11:00:00.000Z"))
        let codexChild = Subagent(id: "k", name: "coder", provider: .codex, state: .idle, sourceReadAt: now, lastActivityAt: now, tokenBuckets: childBuckets)
        let alpha = ProjectSummary(identity: ProjectIdentity(root: "/a", name: "alpha", kind: .folder),
                                   threads: [thread("a1", .claude, [("11:00:00", 100), ("06:00:00", 5000)], children: [codexChild])],
                                   status: .recent, lastActivityAt: now)
        let beta = ProjectSummary(identity: ProjectIdentity(root: "/b", name: "beta", kind: .folder),
                                  threads: [thread("b1", .claude, [("10:30:00", 300)]), thread("b2", .codex, [("10:30:00", 900)])],
                                  status: .recent, lastActivityAt: now)
        // Session window from the provider: resets 14:10, 5 h long → starts 09:10.
        let usage = ProviderUsage(provider: .claude, accountId: "a", plan: nil,
                                  windows: [UsageWindow(id: "session", label: "session", duration: 18000, usedPercent: 41, resetsAt: Fixture.date("2026-10-29T14:10:00.000Z"))],
                                  lastAttemptAt: now, lastSuccessAt: now, lastFailure: nil, status: .fresh, source: "")
        let statuses = [CollectorStatus(source: .claudeCode, lastReadAt: now, threadCount: 3, filesIndexed: 3, filesInWindow: 3, filesNotIndexed: 0, skippedLines: 0)]
        let claude = LocalTokenAttribution(provider: .claude, usage: usage, projects: [alpha, beta], statuses: statuses, now: now)
        #expect(claude.windowFromProvider)
        #expect(claude.window.start == Fixture.date("2026-10-29T09:10:00.000Z"))
        #expect(claude.projects.map(\.project.identity.name) == ["beta", "alpha"])
        #expect(claude.projects.map(\.tokens) == [300, 100])
        #expect(!claude.partial)
        // Codex: the Claude thread's Codex child counts under Codex, once; fallback window is 5 h.
        let codex = LocalTokenAttribution(provider: .codex, usage: nil, projects: [alpha, beta], statuses: statuses, now: now)
        #expect(!codex.windowFromProvider)
        #expect(codex.projects.map(\.tokens) == [900, 700])
        #expect(codex.partial, "no Codex collector status → coverage unknown → partial")
    }

    @Test func bucketsEncodeCompactlyAndPrune() throws {
        var b = TokenBuckets()
        b.add(5, at: Fixture.date("2026-10-01T00:00:00.000Z"))
        b.add(7, at: Fixture.date("2026-10-29T10:02:00.000Z"))
        #expect(b.counts.count == 1, "older than 8 days is pruned when a new bucket opens")
        let data = try JSONEncoder().encode(b)
        #expect(String(decoding: data, as: UTF8.self) == "[\(Int(Fixture.date("2026-10-29T10:00:00.000Z").timeIntervalSince1970 / 300)),7]")
        #expect(try JSONDecoder().decode(TokenBuckets.self, from: data) == b)
    }

    /// A checkpoint written before M2 (no `tokenBuckets`) is not decoded, so its file is read again
    /// from offset 0 and the buckets are rebuilt.
    @Test func preM2CheckpointIsReindexedFromStart() async {
        let s = Scratch()
        let path = s.write(file, meta + line(1, "10:00:00", total: 1000))
        let size = UInt64((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0)
        let stat = ReadOnlyFileSystem().stat(path)!
        let store = MemoryCheckpoints()
        let old = #"{"cwd":"/Users/me/Projects/beta","id":"tok-1","lastTotalTokens":1000,"tokenEpochs":0,"tokens":1000,"tokensPartial":false}"#
        store.saveCheckpoints(source: .codex, changed: [StoredCheckpoint(path: path, device: stat.device, inode: stat.inode, size: size, offset: size,
                                                                          mtime: stat.mtime, skippedLines: 0, skippingLine: false, state: Data(old.utf8))], removed: [])
        let result = await CodexCollector(codexHome: s.codexHome, store: store).pass(now: now, scope: .full)
        #expect(result.bytesRead >= Int(size))
        #expect(thread(result)?.tokenBuckets.total == 1000)
    }
}

// MARK: Round 1 repairs (Sol review docs/reviews/sol-m2-review.md)

@Suite struct UsageRoundOneTests {
    let t0 = UsageFixture.t0

    /// M2-02: a Claude account change (prompting source, valid cached token) resets the readings and
    /// the near-limit mark before anything is shown, and the old token is never used again.
    @Test func claudeAccountSwitchWithCachedTokenResetsReadings() async {
        let credentials = FakeCredentials(UsageFixture.credential(account: "acct-AAAA", token: "token-A"), mayPrompt: true)
        credentials.setAccount("acct-AAAA")
        let transport = ScriptedTransport([.response(200, UsageFixture.claude(session: 88), nil)])
        let monitor = UsageFixture.monitor(.claude, credentials: credentials, transport: transport)
        let a = await monitor.poll(.claude, now: t0)!
        #expect(a.session?.usedPercent == 88)
        #expect(UsageGlyphState(readings: [a], now: t0).nearLimit == .amber)

        // Claude Code signs in to account B; the cached token for A has not expired.
        credentials.setAccount("acct-BBBB")
        credentials.set(UsageFixture.credential(account: "acct-BBBB", token: "token-B"))
        transport.push(.error(.offline))
        let switched = await monitor.poll(.claude, now: t0.addingTimeInterval(120))!
        #expect(switched.accountId == "acct-BBBB")
        #expect(switched.windows.isEmpty)
        #expect(switched.lastSuccessAt == nil)
        #expect(switched.status == .unavailable("Network unavailable"))
        #expect(UsageGlyphState(readings: [switched], now: t0.addingTimeInterval(120)).nearLimit == .none)
        #expect(credentials.loads == 2, "the Keychain is read once more for the new account")
        #expect(transport.requests.last?.header("Authorization") == "Bearer token-B", "A's token is never used under B")

        transport.push(.response(200, UsageFixture.claude(session: 12), nil))
        let fresh = await monitor.poll(.claude, now: t0.addingTimeInterval(240))!
        #expect(fresh.accountAlias == "Account ••BBBB")
        #expect(fresh.session?.usedPercent == 12)
        #expect(transport.requests.map { $0.header("Authorization") } == ["Bearer token-A", "Bearer token-B", "Bearer token-B"])
        #expect(credentials.loads == 2, "no further Keychain reads while B's token is valid")
    }

    /// M2-02: the switch is detected even when the fetch is rate limited and no request is sent.
    @Test func claudeAccountSwitchResetsEvenWhileBackingOff() async {
        let credentials = FakeCredentials(UsageFixture.credential(account: "acct-AAAA"), mayPrompt: true)
        credentials.setAccount("acct-AAAA")
        let transport = ScriptedTransport([.response(200, UsageFixture.claude(session: 97), nil), .response(429, "", 3600)])
        let monitor = UsageFixture.monitor(.claude, credentials: credentials, transport: transport)
        _ = await monitor.poll(.claude, now: t0)
        _ = await monitor.poll(.claude, now: t0.addingTimeInterval(120))
        // Only the identity file changes; the Keychain still returns a token labelled for A.
        credentials.setAccount("acct-BBBB")
        let r = await monitor.poll(.claude, now: t0.addingTimeInterval(240))!
        #expect(r.accountId == "acct-BBBB")
        #expect(r.windows.isEmpty)
        #expect(UsageGlyphState(readings: [r], now: t0.addingTimeInterval(240)).worstPercent == nil)
        // A later success is recorded under B, never back under A.
        transport.push(.response(200, UsageFixture.claude(session: 5), nil))
        let later = await monitor.poll(.claude, now: t0.addingTimeInterval(360))!
        #expect(later.accountId == "acct-BBBB")
    }

    /// M2-03: a 2xx body that does not match the expected schema never becomes a success.
    @Test func schemaInvalidSuccessBodiesAreUnavailable() async {
        let claudeBodies = [
            "{}", #"{"error":{"type":"authentication_error","message":"x"}}"#, #"{"type":"error"}"#,
            #"{"five_hour":"41"}"#, #"{"five_hour":{"utilization":"41","resets_at":null}}"#,
            #"{"five_hour":{"utilization":true,"resets_at":null}}"#, #"{"five_hour":{"utilization":41,"resets_at":12}}"#,
            #"{"five_hour":{"utilization":41,"resets_at":"not a date"}}"#, #"{"seven_day":[]}"#,
            #"{"five_hour":{"utilization":-3,"resets_at":null}}"#,
            // Round 2 (recheck 1): present window without its percentage; no window at all.
            #"{"five_hour":{}}"#, #"{"seven_day":{"resets_at":"2026-10-30T09:00:00+00:00"}}"#,
            #"{"five_hour":{"utilization":null,"resets_at":null}}"#, #"{"five_hour":null,"seven_day":null}"#,
            #"{"five_hour":{"utilization":41,"resets_at":null},"seven_day_sonnet":{}}"#,
        ]
        let codexBodies = [
            "{}", #"{"error":{"message":"x"}}"#, #"{"detail":"Unauthorized"}"#, #"{"plan_type":"plus"}"#,
            #"{"rate_limit":"x"}"#, #"{"rate_limit":null}"#, #"{"rate_limit":{"primary_window":{"used_percent":"88"}}}"#,
            #"{"rate_limit":{"primary_window":{"reset_at":1}}}"#, #"{"rate_limit":{"primary_window":{"used_percent":5,"reset_at":"soon"}}}"#,
            #"{"rate_limit":{"primary_window":[]}}"#, #"{"plan_type":7,"rate_limit":{}}"#,
            #"{"rate_limit":{"primary_window":{"used_percent":5}},"additional_rate_limits":{"x":1}}"#,
            // Round 2 (recheck 1): no recognized window key; windows all null; window without percent.
            #"{"rate_limit":{}}"#, #"{"plan_type":"plus","rate_limit":{"allowed":true,"limit_reached":false}}"#,
            #"{"rate_limit":{"primary_window":null,"secondary_window":null}}"#, #"{"rate_limit":{"primary_window":{}}}"#,
        ]
        for (provider, bodies) in [(Provider.claude, claudeBodies), (.codex, codexBodies)] {
            for body in bodies {
                // Cold: no success timestamp, no windows.
                let cold = UsageFixture.monitor(provider, credentials: FakeCredentials(UsageFixture.credential()),
                                                transport: ScriptedTransport([.response(200, body, nil)]))
                let r = await cold.poll(provider, now: t0)!
                #expect(r.status == .unavailable("Unexpected response"), "\(provider) \(body)")
                #expect(r.lastSuccessAt == nil, "\(provider) \(body)")
                #expect(r.windows.isEmpty)
                // After a real success: the success age is not refreshed.
                let good = provider == .claude ? UsageFixture.claude(session: 41) : UsageFixture.codex(primary: 41)
                let warm = UsageFixture.monitor(provider, credentials: FakeCredentials(UsageFixture.credential()),
                                                transport: ScriptedTransport([.response(200, good, nil), .response(200, body, nil)]))
                _ = await warm.poll(provider, now: t0)
                let w = await warm.poll(provider, now: t0.addingTimeInterval(120))!
                #expect(w.lastSuccessAt == t0, "\(provider) \(body)")
                #expect(w.lastFailure == .malformedResponse, "\(provider) \(body)")
            }
        }
    }

    /// M2-03 discriminator: a valid weekly-only Codex response and valid
    /// null windows are still accepted.
    @Test func validResponsesWithMissingWindowsAreAccepted() async throws {
        let weeklyOnly = #"{"user_id":"u","account_id":"a","email":"e","plan_type":"plus","rate_limit":{"allowed":true,"limit_reached":false,"primary_window":{"used_percent":44,"limit_window_seconds":604800,"reset_after_seconds":250000,"reset_at":1793600000},"secondary_window":null},"code_review_rate_limit":null,"additional_rate_limits":null,"credits":{"has_credits":true,"unlimited":false,"balance":"1000"}}"#
        let credential = UsageCredential(accessToken: "t", accountId: "acct-1111", plan: nil, expiresAt: nil)
        let codex = try CodexUsageAdapter().parse(Data(weeklyOnly.utf8), credential: credential, now: t0)
        #expect(codex.windows.map(\.id) == ["weekly"])
        #expect(codex.windows[0].usedPercent == 44)
        let claude = try ClaudeUsageAdapter().parse(Data(#"{"five_hour":null,"seven_day":{"utilization":63.0,"resets_at":"2026-10-30T09:00:00+00:00"},"seven_day_opus":null}"#.utf8),
                                                    credential: credential, now: t0)
        #expect(claude.windows.map(\.id) == ["weekly"])
        // An optional model pool with an explicit null percentage is omitted, not malformed.
        let pool = try ClaudeUsageAdapter().parse(Data(#"{"five_hour":{"utilization":3,"resets_at":null},"seven_day":null,"seven_day_opus":{"utilization":null,"resets_at":null}}"#.utf8),
                                                  credential: credential, now: t0)
        #expect(pool.windows.map(\.id) == ["session"])
        let monitor = UsageFixture.monitor(.codex, credentials: FakeCredentials(UsageFixture.credential()),
                                           transport: ScriptedTransport([.response(200, weeklyOnly, nil)]))
        let r = await monitor.poll(.codex, now: t0)!
        #expect(r.status == .fresh)
        #expect(r.session == nil && r.weekly?.usedPercent == 44)
    }

    /// Round 2 rule: every successful parse of either adapter yields at least one window.
    @Test func successfulParseYieldsAtLeastOneWindow() throws {
        let credential = UsageCredential(accessToken: "t", accountId: "a", plan: nil, expiresAt: nil)
        for body in [#"{"five_hour":null,"seven_day":null,"seven_day_opus":null}"#, #"{"five_hour":{}}"#] {
            #expect(throws: (any Error).self) { try ClaudeUsageAdapter().parse(Data(body.utf8), credential: credential, now: t0) }
        }
        for body in [#"{"rate_limit":{}}"#, #"{"rate_limit":{"primary_window":null,"secondary_window":null},"additional_rate_limits":[]}"#] {
            #expect(throws: (any Error).self) { try CodexUsageAdapter().parse(Data(body.utf8), credential: credential, now: t0) }
        }
        for body in [UsageFixture.claude(session: 1), UsageFixture.claude(session: 1, weekly: nil)] {
            #expect(try !ClaudeUsageAdapter().parse(Data(body.utf8), credential: credential, now: t0).windows.isEmpty)
        }
        for body in [UsageFixture.codex(primary: 1), UsageFixture.codex(primary: 1, secondary: nil)] {
            #expect(try !CodexUsageAdapter().parse(Data(body.utf8), credential: credential, now: t0).windows.isEmpty)
        }
    }

    /// M2-04: only whole 5-minute buckets inside [start, end] count; events just before the start or
    /// just after the end are never included.
    @Test func windowBoundariesNeverIncludeOutsideTokens() {
        var b = TokenBuckets()
        let at = { (s: Double) in Date(timeIntervalSince1970: s) }
        b.add(1_000_000, at: at(1))          // bucket [0, 300)
        b.add(10, at: at(300))               // bucket [300, 600)
        b.add(20, at: at(899))               // bucket [600, 900)
        b.add(5_000, at: at(901))            // bucket [900, 1200)
        // Reviewer's case: [299, 600] must not include the token at second 1.
        #expect(b.sum(in: DateInterval(start: at(299), end: at(600))) == 10)
        // Start exactly on a bucket edge includes that bucket; one second later excludes it.
        #expect(b.sum(in: DateInterval(start: at(300), end: at(900))) == 30)
        #expect(b.sum(in: DateInterval(start: at(301), end: at(900))) == 20)
        // End one second before the bucket that holds second 901: that bucket is excluded.
        #expect(b.sum(in: DateInterval(start: at(0), end: at(1199))) == 1_000_030)
        #expect(b.sum(in: DateInterval(start: at(0), end: at(1200))) == 1_005_030)
        // No whole bucket fits: zero, never a partial count.
        #expect(b.sum(in: DateInterval(start: at(301), end: at(599))) == 0)
        #expect(TokenBuckets.counted(DateInterval(start: at(299), end: at(1150))) == DateInterval(start: at(300), end: at(900)))
        #expect(TokenBuckets.counted(DateInterval(start: at(301), end: at(599))) == nil)
    }

    @Test func attributionReportsTheCountedInterval() {
        let now = Fixture.date("2026-10-29T12:03:20.000Z")
        let usage = ProviderUsage(provider: .claude, accountId: "a", plan: nil,
                                  windows: [UsageWindow(id: "session", label: "session", duration: 18000, usedPercent: 41,
                                                        resetsAt: Fixture.date("2026-10-29T14:11:40.000Z"))],
                                  lastAttemptAt: now, lastSuccessAt: now, lastFailure: nil, status: .fresh, source: "")
        let a = LocalTokenAttribution(provider: .claude, usage: usage, projects: [], statuses: [], now: now)
        #expect(a.window.start == Fixture.date("2026-10-29T09:11:40.000Z"))
        #expect(a.counted == DateInterval(start: Fixture.date("2026-10-29T09:15:00.000Z"), end: Fixture.date("2026-10-29T12:00:00.000Z")))
    }
}
