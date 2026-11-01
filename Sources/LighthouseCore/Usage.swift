import Foundation

/// One quota window as the provider reports it (SPEC §5.5). `usedPercent` means **used**; every
/// user-visible figure is percent **left** (`UsagePace`, SPEC 2.7).
public struct UsageWindow: Sendable, Hashable, Codable, Identifiable {
    /// `session`, `weekly`, or a named pool id (`opus-week`, a Codex `limit_name`).
    public var id: String
    /// Shown label for named pools ("Opus week"); session and weekly use fixed labels.
    public var label: String
    public var duration: TimeInterval?
    public var usedPercent: Double
    public var resetsAt: Date?

    public static let sessionId = "session"
    public static let weeklyId = "weekly"

    public init(id: String, label: String, duration: TimeInterval?, usedPercent: Double, resetsAt: Date?) {
        self.id = id
        self.label = label
        self.duration = duration
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    public var isPool: Bool { id != Self.sessionId && id != Self.weeklyId }

    /// True once the reported reset time has passed: the percent no longer describes the window.
    public func hasReset(now: Date) -> Bool { resetsAt.map { $0 <= now } ?? false }
}

/// What a successful fetch returned. No field holds a credential (V-SECRETS).
public struct UsageSample: Sendable, Hashable {
    /// Stable id from the source (Claude `oauthAccount.accountUuid`, Codex `tokens.account_id`).
    public var accountId: String?
    public var plan: String?
    public var windows: [UsageWindow]

    public init(accountId: String?, plan: String?, windows: [UsageWindow]) {
        self.accountId = accountId
        self.plan = plan
        self.windows = windows
    }
}

/// Why a fetch failed. Reasons are fixed phrases; they never carry response bodies, headers,
/// error descriptions, or credentials, so nothing secret can reach the UI, logs, or store.
public enum UsageFailure: Error, Sendable, Hashable {
    /// 401/403, missing credentials, or an expired token (no refresh in v2.0, SPEC §4).
    case signInRequired
    case keychainDenied
    case networkUnavailable
    case timedOut
    case rateLimited(retryAfter: Date?)
    case malformedResponse
    case server(Int)
    case unreadableCredentials
    case blockedEndpoint

    public var reason: String {
        switch self {
        case .signInRequired: "Sign in again"
        case .keychainDenied: "Keychain access denied · Retry in Settings"
        case .networkUnavailable: "Network unavailable"
        case .timedOut: "Request timed out"
        case .rateLimited: "Rate limited by provider"
        case .malformedResponse: "Unexpected response"
        case .server(let code): "Provider error \(code)"
        case .unreadableCredentials: "Credentials unreadable"
        case .blockedEndpoint: "Endpoint not allowed"
        }
    }

    /// Short machine-safe kind for logs.
    public var kind: String {
        switch self {
        case .signInRequired: "signInRequired"
        case .keychainDenied: "keychainDenied"
        case .networkUnavailable: "network"
        case .timedOut: "timeout"
        case .rateLimited: "rateLimited"
        case .malformedResponse: "malformed"
        case .server(let code): "server\(code)"
        case .unreadableCredentials: "unreadableCredentials"
        case .blockedEndpoint: "blockedEndpoint"
        }
    }
}

/// SPEC §5.5 status.
public enum UsageStatus: Sendable, Hashable {
    case fresh
    case stale
    case unavailable(String)
    case signInRequired
}

/// The displayed reading for one provider (SPEC §5.5 `UsageReading`, all windows together).
public struct ProviderUsage: Sendable, Hashable, Identifiable {
    public var id: Provider { provider }
    public var provider: Provider
    public var accountId: String?
    public var plan: String?
    /// Windows from the last success for the current account. Empty when none is known.
    public var windows: [UsageWindow]
    public var lastAttemptAt: Date?
    public var lastSuccessAt: Date?
    public var lastFailure: UsageFailure?
    public var status: UsageStatus
    /// Where the reading comes from, for the provider page.
    public var source: String

    /// Shown alias: never the e-mail address or a token, only the tail of the stable account id.
    public var accountAlias: String? {
        guard let accountId, !accountId.isEmpty else { return nil }
        let tail = accountId.filter { $0.isLetter || $0.isNumber }.suffix(4)
        return "Account ••\(tail)"
    }

    /// Windows that may be drawn as bars: only with a known reading for this account and never
    /// after their reset time (V-TRUTH). Sign-in required shows no bars at all (SPEC §4).
    public func displayWindows(now: Date) -> [UsageWindow] {
        switch status {
        case .fresh, .stale: windows.filter { !$0.hasReset(now: now) }
        case .unavailable, .signInRequired: []
        }
    }

    public var session: UsageWindow? { windows.first { $0.id == UsageWindow.sessionId } }
    public var weekly: UsageWindow? { windows.first { $0.id == UsageWindow.weeklyId } }
}

/// Last-known usage for one provider and how fresh it is. Failed attempts move `lastAttemptAt`
/// only; `lastSuccessAt` changes only on success (SPEC §11 M2(3)).
public struct UsageTracker: Sendable, Hashable {
    public let provider: Provider
    public let pollInterval: TimeInterval
    public private(set) var accountId: String?
    public private(set) var plan: String?
    public private(set) var windows: [UsageWindow] = []
    public private(set) var lastAttemptAt: Date?
    public private(set) var lastSuccessAt: Date?
    public private(set) var lastFailure: UsageFailure?
    /// First attempt of this run; used for "stale > 10 min" when nothing ever succeeded.
    public private(set) var firstAttemptAt: Date?

    public init(provider: Provider, pollInterval: TimeInterval) {
        self.provider = provider
        self.pollInterval = pollInterval
    }

    /// SPEC §5.5: fresh = last success younger than 3 poll intervals.
    public var freshFor: TimeInterval { pollInterval * 3 }

    /// Account change resets that provider's readings (SPEC §5.5). Call with the account the
    /// credentials name before fetching, and again with the account a response reports.
    public mutating func observeAccount(_ id: String?) {
        guard let id, !id.isEmpty, id != accountId else { return }
        if accountId != nil {
            windows = []
            plan = nil
            lastSuccessAt = nil
            lastFailure = nil
        }
        accountId = id
    }

    public mutating func recordSuccess(_ sample: UsageSample, at now: Date) {
        observeAccount(sample.accountId)
        firstAttemptAt = firstAttemptAt ?? now
        lastAttemptAt = now
        lastSuccessAt = now
        lastFailure = nil
        plan = sample.plan ?? plan
        windows = sample.windows
    }

    public mutating func recordFailure(_ failure: UsageFailure, at now: Date) {
        firstAttemptAt = firstAttemptAt ?? now
        lastAttemptAt = now
        lastFailure = failure
    }

    /// Owner turned the provider off, or retried from scratch.
    public mutating func clear() {
        self = UsageTracker(provider: provider, pollInterval: pollInterval)
    }

    public func status(now: Date) -> UsageStatus {
        if lastFailure == .signInRequired { return .signInRequired }
        if let lastSuccessAt {
            return now.timeIntervalSince(lastSuccessAt) < freshFor ? .fresh : .stale
        }
        if let lastFailure { return .unavailable(lastFailure.reason) }
        return .unavailable("Checking…")
    }

    public func reading(now: Date, source: String) -> ProviderUsage {
        ProviderUsage(provider: provider, accountId: accountId, plan: plan, windows: windows, lastAttemptAt: lastAttemptAt,
                      lastSuccessAt: lastSuccessAt, lastFailure: lastFailure, status: status(now: now), source: source)
    }

    /// True when usage has not been confirmed for more than `bound` (SPEC §6.1 stale glyph).
    public func isStale(now: Date, bound: TimeInterval = 600) -> Bool {
        guard let since = lastSuccessAt ?? firstAttemptAt else { return false }
        return now.timeIntervalSince(since) > bound
    }
}

/// SPEC §6.1 near-limit mark: amber at ≤ 20 % left (≥ 80 % used), red at ≤ 5 % left (≥ 95 % used).
public enum NearLimit: Int, Sendable, Hashable, Comparable {
    case none = 0
    case amber = 1
    case red = 2

    public static func < (a: NearLimit, b: NearLimit) -> Bool { a.rawValue < b.rawValue }

    public static func level(_ percent: Double) -> NearLimit {
        percent >= 95 ? .red : percent >= 80 ? .amber : .none
    }

    /// The same marks from percent left.
    public static func level(left: Double) -> NearLimit { level(100 - left) }
}

/// Menu bar marks derived from usage (SPEC §6.1). Only fresh windows that have not reset count.
public struct UsageGlyphState: Sendable, Hashable {
    public var nearLimit: NearLimit
    /// Worst (highest) fresh used percent.
    public var worstPercent: Double?
    /// Description of the worst window for VoiceOver ("Codex session 12 percent left").
    public var worstDescription: String?
    /// Every enabled provider has had no success for more than 10 minutes.
    public var allStale: Bool

    public init(nearLimit: NearLimit, worstPercent: Double?, worstDescription: String?, allStale: Bool) {
        self.nearLimit = nearLimit
        self.worstPercent = worstPercent
        self.worstDescription = worstDescription
        self.allStale = allStale
    }

    public init(readings: [ProviderUsage], trackers: [UsageTracker] = [], now: Date) {
        var worst: (Double, String)?
        for reading in readings where reading.status == .fresh {
            for window in reading.displayWindows(now: now) where worst == nil || window.usedPercent > worst!.0 {
                let left = UsagePace(window: window, now: now).left
                worst = (window.usedPercent, "\(reading.provider.displayName) \(UsageText.windowName(window)) \(Int(left.rounded())) percent left")
            }
        }
        nearLimit = worst.map { NearLimit.level($0.0) } ?? .none
        worstPercent = worst?.0
        worstDescription = worst?.1
        allStale = !trackers.isEmpty && trackers.allSatisfy { $0.isStale(now: now) }
    }

    /// Least fresh percent left, for the optional menu bar text ("12% left").
    public var worstLeft: Double? { worstPercent.map { min(max(100 - $0, 0), 100) } }
}

/// Shared wording for usage rows (used by the app and VoiceOver).
public enum UsageText {
    public static func windowName(_ window: UsageWindow) -> String {
        switch window.id {
        case UsageWindow.sessionId: "session"
        case UsageWindow.weeklyId: "week"
        default: window.label
        }
    }

    /// Capitalized plan name: `max` → `Max`, `pro` → `Pro`, `claude_max_20x` → `Max 20x`.
    public static func plan(_ raw: String?) -> String? {
        guard var raw, !raw.isEmpty else { return nil }
        for prefix in ["default_", "claude_", "chatgpt_"] where raw.hasPrefix(prefix) { raw.removeFirst(prefix.count) }
        return raw.split(separator: "_").map { word in
            word.first.map { String($0).uppercased() + word.dropFirst() } ?? ""
        }.joined(separator: " ")
    }
}

/// Owner switches for usage (SPEC §6.6 Usage, General worst-% text). Providers are off until the
/// owner enables them, so no credential is read and no request is made before that.
public struct UsageSettings: Sendable, Hashable {
    public var enabled: Set<Provider>
    public var showWorstPercent: Bool

    public init(enabled: Set<Provider> = [], showWorstPercent: Bool = false) {
        self.enabled = enabled
        self.showWorstPercent = showWorstPercent
    }

    init(values: [String: Int]) {
        enabled = Set(Provider.allCases.filter { values["enabled.\($0.rawValue)"] == 1 })
        showWorstPercent = values["menuBarPercent"] == 1
    }

    var values: [String: Int] {
        var result = ["menuBarPercent": showWorstPercent ? 1 : 0]
        for provider in Provider.allCases { result["enabled.\(provider.rawValue)"] = enabled.contains(provider) ? 1 : 0 }
        return result
    }
}

/// Percent left and pace for one window (SPEC 2.7 §5.5; M6 contract Definitions, CodexBar style).
/// Pace is linear over the window: the expected use at any moment is the share of the window that
/// has passed. Without a duration and a reset time nothing but percent left is known, so pace and
/// projection stay nil and are never guessed (V-TRUTH).
public struct UsagePace: Sendable, Hashable {
    public enum Projection: Sendable, Hashable {
        /// The current rate does not empty the window before it resets (or nothing is used yet).
        case lastsUntilReset
        /// At the current rate the window is empty this long from now, before its reset.
        case runsOut(in: TimeInterval)
        /// Nothing is left; the window resets this long from now.
        case out(resetIn: TimeInterval)
    }

    /// Pace text is left out while less than this share of the window has passed.
    public static let minimumElapsedShare = 0.03

    /// `clamp(100 − usedPercent, 0, 100)`.
    public let left: Double
    /// Time until the reported reset; nil without one.
    public let resetIn: TimeInterval?
    /// Seconds of the window that have passed; nil without duration and a future reset.
    public let elapsed: TimeInterval?
    /// `100 × elapsed / duration`; nil when pace is not shown (unknown, reset passed, or too early).
    public let expectedUsed: Double?
    /// `expectedUsed − usedPercent` rounded to a whole percent: positive is reserve, negative deficit.
    public let delta: Int?
    public let projection: Projection?

    public init(window: UsageWindow, now: Date) {
        let used = window.usedPercent
        left = min(max(100 - used, 0), 100)
        resetIn = window.resetsAt.map { max(0, $0.timeIntervalSince(now)) }
        guard let duration = window.duration, duration > 0, let resetsAt = window.resetsAt, resetsAt > now else {
            elapsed = nil; expectedUsed = nil; delta = nil; projection = nil
            return
        }
        let remaining = resetsAt.timeIntervalSince(now)
        let elapsed = min(max(duration - remaining, 0), duration)
        self.elapsed = elapsed
        guard elapsed >= Self.minimumElapsedShare * duration else {
            expectedUsed = nil; delta = nil; projection = nil
            return
        }
        let expected = 100 * elapsed / duration
        expectedUsed = expected
        delta = Int((expected - used).rounded())
        if used <= 0 {
            projection = .lastsUntilReset
        } else if used >= 100 {
            projection = .out(resetIn: remaining)
        } else {
            let rate = used / elapsed
            let timeToEmpty = (100 - used) / rate
            projection = timeToEmpty >= remaining ? .lastsUntilReset : .runsOut(in: timeToEmpty)
        }
    }

    /// Bar fill, 0…1: the bar shows what is **left**.
    public var barFill: Double { left / 100 }
    /// Expected-pace marker on the bar, 0…1: where the fill would end at an even pace.
    public var marker: Double? { expectedUsed.map { min(max(100 - $0, 0), 100) / 100 } }
}

extension UsageText {
    /// "83% left".
    public static func left(_ pace: UsagePace) -> String { "\(Int(pace.left.rounded()))% left" }

    /// "2% in deficit", "40% in reserve", "On pace"; nil when pace is not known.
    public static func pace(_ pace: UsagePace) -> String? {
        guard let delta = pace.delta else { return nil }
        if delta >= 1 { return "\(delta)% in reserve" }
        if delta <= -1 { return "\(-delta)% in deficit" }
        return "On pace"
    }

    /// "Runs out in 5d", "Lasts until reset", "Out · resets in 2h"; nil when not known.
    public static func projection(_ pace: UsagePace) -> String? {
        switch pace.projection {
        case nil: nil
        case .lastsUntilReset: "Lasts until reset"
        case .runsOut(let time): "Runs out in \(duration(time))"
        case .out(let reset): "Out · resets in \(duration(reset))"
        }
    }

    /// "2% in deficit · Runs out in 5d"; nil when neither is known.
    public static func paceLine(_ pace: UsagePace) -> String? {
        let parts = [self.pace(pace), projection(pace)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "resets in 6d 2h"; nil without a reset time.
    public static func resetIn(_ pace: UsagePace) -> String? { pace.resetIn.map { "resets in \(duration($0))" } }

    /// `5d`, `1d 4h`, `3h 20m`, `40m`, `<1m`. Rounded to the nearest minute (under a day) or hour.
    public static func duration(_ seconds: TimeInterval) -> String {
        let parts = durationParts(seconds)
        switch parts {
        case .underAMinute: return "<1m"
        case .minutes(let m): return "\(m)m"
        case .hours(let h, let m): return m == 0 ? "\(h)h" : "\(h)h \(m)m"
        case .days(let d, let h): return h == 0 ? "\(d)d" : "\(d)d \(h)h"
        }
    }

    /// The same duration in words for VoiceOver: "5 days", "1 day 4 hours", "less than a minute".
    public static func spokenDuration(_ seconds: TimeInterval) -> String {
        func unit(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        switch durationParts(seconds) {
        case .underAMinute: return "less than a minute"
        case .minutes(let m): return unit(m, "minute")
        case .hours(let h, let m): return m == 0 ? unit(h, "hour") : unit(h, "hour") + " " + unit(m, "minute")
        case .days(let d, let h): return h == 0 ? unit(d, "day") : unit(d, "day") + " " + unit(h, "hour")
        }
    }

    private enum DurationParts { case underAMinute, minutes(Int), hours(Int, Int), days(Int, Int) }

    private static func durationParts(_ seconds: TimeInterval) -> DurationParts {
        let minutes = Int((max(seconds, 0) / 60).rounded())
        if minutes < 1 { return .underAMinute }
        if minutes < 60 { return .minutes(minutes) }
        if minutes < 24 * 60 { return .hours(minutes / 60, minutes % 60) }
        let hours = Int((seconds / 3600).rounded())
        return .days(hours / 24, hours % 24)
    }

    /// VoiceOver: "83 percent left, 2 percent in deficit, runs out in 5 days, resets in 6 days".
    public static func spoken(_ pace: UsagePace) -> String {
        var parts = ["\(Int(pace.left.rounded())) percent left"]
        if let delta = pace.delta {
            parts.append(delta >= 1 ? "\(delta) percent in reserve" : delta <= -1 ? "\(-delta) percent in deficit" : "on pace")
        }
        switch pace.projection {
        case nil: break
        case .lastsUntilReset: parts.append("lasts until reset")
        case .runsOut(let time): parts.append("runs out in \(spokenDuration(time))")
        case .out: parts.append("out")
        }
        if let reset = pace.resetIn { parts.append("resets in \(spokenDuration(reset))") }
        return parts.joined(separator: ", ")
    }

    /// One log line of pace inputs and outputs for a window (M6 C4 recompute; numbers only, no secrets).
    public static func paceLog(provider: Provider, window: UsageWindow, now: Date) -> String {
        let pace = UsagePace(window: window, now: now)
        func number(_ value: Double?) -> String { value.map { String(format: "%.6f", $0) } ?? "-" }
        let projection: String = switch pace.projection {
        case nil: "-"
        case .lastsUntilReset: "lastsUntilReset"
        case .runsOut(let t): "runsOut:" + String(format: "%.3f", t)
        case .out(let r): "out:" + String(format: "%.3f", r)
        }
        return "usage pace provider=\(provider.rawValue) window=\(window.id) used=\(number(window.usedPercent))"
            + " duration=\(number(window.duration)) resetsAt=\(number(window.resetsAt?.timeIntervalSince1970))"
            + " now=\(number(now.timeIntervalSince1970)) left=\(number(pace.left)) expectedUsed=\(number(pace.expectedUsed))"
            + " delta=\(pace.delta.map(String.init) ?? "-") projection=\(projection)"
            + " text=\"\(left(pace))\(paceLine(pace).map { " · " + $0 } ?? "")\(resetIn(pace).map { " · " + $0 } ?? "")\""
    }
}
