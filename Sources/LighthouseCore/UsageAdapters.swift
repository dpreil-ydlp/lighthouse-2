import Foundation

// MARK: Credentials

/// An access token held in memory only. It prints as `<redacted>` in every description, dump, and
/// mirror, so string interpolation or a debugger dump cannot leak it (V-SECRETS).
public struct UsageCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let accessToken: String
    public var accountId: String?
    public var plan: String?
    public var expiresAt: Date?

    public init(accessToken: String, accountId: String?, plan: String?, expiresAt: Date?) {
        self.accessToken = accessToken
        self.accountId = accountId
        self.plan = plan
        self.expiresAt = expiresAt
    }

    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }

    public func isExpired(now: Date) -> Bool { expiresAt.map { $0 <= now } ?? false }
}

public enum CredentialResult: Sendable {
    case found(UsageCredential)
    /// No credential: the CLI is not signed in (or uses an API key, which has no plan usage).
    case missing
    /// The owner denied the Keychain prompt.
    case denied
    case unreadable
}

public protocol UsageCredentialSource: Sendable {
    /// Where the credential lives, for the provider page ("Keychain · Claude Code-credentials").
    var location: String { get }
    /// True when each read may show a system prompt (the Keychain), so reads are rationed.
    var mayPrompt: Bool { get }
    func load() -> CredentialResult
    /// The signed-in account, read without any prompt (Claude: `~/.claude.json`). Checked on every
    /// poll so an account change resets readings even while a cached token is still valid. Nil when
    /// the source has no separate identity (Codex: the identity comes with each `auth.json` read).
    func currentAccountId() -> String?
}

extension UsageCredentialSource {
    public func currentAccountId() -> String? { nil }
}

/// `~/.codex/auth.json`, read in place through the read-only boundary (no copy, no symlink).
public struct CodexAuthFile: UsageCredentialSource {
    public let path: String
    let access: SourceAccess

    public init(codexHome: String = NSHomeDirectory() + "/.codex", access: SourceAccess = ReadOnlyFileSystem()) {
        self.path = (codexHome as NSString).appendingPathComponent("auth.json")
        self.access = access
    }

    public var location: String { "~/.codex/auth.json" }
    public var mayPrompt: Bool { false }

    public func load() -> CredentialResult {
        guard let stat = access.stat(path), !stat.isSymlink else { return .missing }
        guard stat.size < 1 << 20, let data = access.read(path, offset: 0, count: Int(stat.size)) else { return .unreadable }
        return Self.parse(data)
    }

    static func parse(_ data: Data) -> CredentialResult {
        struct Auth: Decodable {
            var tokens: Tokens?
            struct Tokens: Decodable { var access_token: String?; var account_id: String? }
        }
        guard let auth = try? JSONDecoder().decode(Auth.self, from: data) else { return .unreadable }
        guard let token = auth.tokens?.access_token, !token.isEmpty else { return .missing }
        return .found(UsageCredential(accessToken: token, accountId: auth.tokens?.account_id, plan: nil,
                                      expiresAt: JWT.expiry(token)))
    }
}

enum JWT {
    /// `exp` from the payload of a JWT, without verifying it. Nil when the token is not a JWT.
    static func expiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        struct Claims: Decodable { var exp: Double? }
        guard let data = Data(base64Encoded: base64), let exp = (try? JSONDecoder().decode(Claims.self, from: data))?.exp else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}

/// Parses the Keychain item `Claude Code-credentials` (`claudeAiOauth.accessToken`, `expiresAt`
/// in ms, `subscriptionType`) and takes the account id from `~/.claude.json` `oauthAccount.accountUuid`
/// (only that key is decoded).
public enum ClaudeCredentialParser {
    static func parse(_ data: Data, accountId: String?) -> CredentialResult {
        struct Item: Decodable {
            var claudeAiOauth: OAuth?
            struct OAuth: Decodable { var accessToken: String?; var expiresAt: Double?; var subscriptionType: String? }
        }
        guard let item = try? JSONDecoder().decode(Item.self, from: data) else { return .unreadable }
        guard let oauth = item.claudeAiOauth, let token = oauth.accessToken, !token.isEmpty else { return .missing }
        return .found(UsageCredential(accessToken: token, accountId: accountId, plan: oauth.subscriptionType,
                                      expiresAt: oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) }))
    }

    /// `oauthAccount.accountUuid` from `~/.claude.json`, read in place, bounded to 16 MB.
    public static func accountId(claudeJSON path: String = NSHomeDirectory() + "/.claude.json",
                                 access: SourceAccess = ReadOnlyFileSystem()) -> String? {
        guard let stat = access.stat(path), !stat.isSymlink, stat.size < 16 << 20,
              let data = access.read(path, offset: 0, count: Int(stat.size)) else { return nil }
        struct Config: Decodable {
            var oauthAccount: Account?
            struct Account: Decodable { var accountUuid: String? }
        }
        return (try? JSONDecoder().decode(Config.self, from: data))?.oauthAccount?.accountUuid
    }
}

// MARK: Transport

/// One GET to an allowlisted usage endpoint. Headers carry the token and are never logged.
public struct UsageRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let url: URL
    let headers: [String: String]

    public var description: String { "GET \(url.absoluteString)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["url": url]) }
    public func header(_ name: String) -> String? { headers[name] }
}

public struct UsageHTTPResponse: Sendable {
    public var status: Int
    public var body: Data
    public var retryAfter: TimeInterval?

    public init(status: Int, body: Data, retryAfter: TimeInterval? = nil) {
        self.status = status
        self.body = body
        self.retryAfter = retryAfter
    }
}

/// Transport failures, with no description text from the system (it could echo request details).
public enum UsageTransportError: Error, Sendable {
    case offline
    case timedOut
    case blocked
    case failed
}

public protocol UsageTransport: Sendable {
    func get(_ request: UsageRequest) async throws(UsageTransportError) -> UsageHTTPResponse
}

/// The only network destinations Lighthouse may contact (SPEC §2 V-NET, §4).
public enum UsageEndpoints {
    public static let claude = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let codex = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    public static let allowed: Set<URL> = [claude, codex]

    public static func isAllowed(_ url: URL) -> Bool { url.scheme == "https" && allowed.contains(url) }
}

// MARK: Adapters

/// Builds the request for and parses the response of one provider's usage endpoint.
public protocol UsageAdapter: Sendable {
    var provider: Provider { get }
    var endpoint: URL { get }
    func request(for credential: UsageCredential) -> UsageRequest
    /// Parses a 200 body. Throws on malformed JSON.
    func parse(_ body: Data, credential: UsageCredential, now: Date) throws -> UsageSample
}

struct MalformedUsage: Error {}

/// `GET https://api.anthropic.com/api/oauth/usage` with the Claude Code OAuth token. Request shape
/// follows CodexBar 0.82.0 (MIT; re-implemented, not copied): `anthropic-beta: oauth-2025-04-20`.
public struct ClaudeUsageAdapter: UsageAdapter {
    public let provider = Provider.claude
    public let endpoint = UsageEndpoints.claude
    public init() {}

    public func request(for credential: UsageCredential) -> UsageRequest {
        UsageRequest(url: endpoint, headers: [
            "Authorization": "Bearer \(credential.accessToken)",
            "Accept": "application/json",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": "claude-cli/2.1.0 (external, cli)",
        ])
    }

    /// Known optional model pools (SPEC §4 "+ optional model pools").
    static let pools: [(key: String, id: String, label: String)] = [
        ("seven_day_opus", "opus-week", "Opus week"),
        ("seven_day_sonnet", "sonnet-week", "Sonnet week"),
        ("seven_day_oauth_apps", "oauth-apps-week", "OAuth apps week"),
    ]

    /// Accepts only the documented shape: an object with `five_hour` and/or `seven_day` keys (a null
    /// window is a missing window). Malformed, so never a success (V-TRUTH): an empty object, an error
    /// object, a known window with wrongly typed fields, a present session or weekly window without a
    /// numeric `utilization` (`{"five_hour":{}}`), or a body that yields no window at all. A model pool
    /// with `utilization: null` is omitted (the pool is optional); a pool without the key is malformed.
    public func parse(_ body: Data, credential: UsageCredential, now: Date) throws -> UsageSample {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any], object["error"] == nil,
              object.keys.contains("five_hour") || object.keys.contains("seven_day") else { throw MalformedUsage() }
        var windows: [UsageWindow] = []
        func add(_ key: String, id: String, label: String, duration: TimeInterval, optional: Bool = false) throws {
            guard let w = try StrictJSON.object(object[key]) else { return }
            guard w.keys.contains("utilization") else { throw MalformedUsage() }
            let resetText = try StrictJSON.string(w["resets_at"])
            let reset = try resetText.map { text in
                guard let date = ISODates.parse(text) else { throw MalformedUsage() }
                return date
            }
            guard let used = try StrictJSON.percent(w["utilization"]) else {
                if optional { return }
                throw MalformedUsage()
            }
            windows.append(UsageWindow(id: id, label: label, duration: duration, usedPercent: used, resetsAt: reset))
        }
        try add("five_hour", id: UsageWindow.sessionId, label: "session", duration: 5 * 3600)
        try add("seven_day", id: UsageWindow.weeklyId, label: "week", duration: 7 * 86400)
        for pool in Self.pools { try add(pool.key, id: pool.id, label: pool.label, duration: 7 * 86400, optional: true) }
        // A successful parse yields at least one window.
        guard !windows.isEmpty else { throw MalformedUsage() }
        return UsageSample(accountId: credential.accountId, plan: credential.plan, windows: windows)
    }
}

/// `GET https://chatgpt.com/backend-api/wham/usage` with the Codex CLI token from `auth.json`
/// (`rate_limit.primary_window` / `secondary_window`: `used_percent`, `reset_at`, `limit_window_seconds`).
public struct CodexUsageAdapter: UsageAdapter {
    public let provider = Provider.codex
    public let endpoint = UsageEndpoints.codex
    public init() {}

    public func request(for credential: UsageCredential) -> UsageRequest {
        var headers = [
            "Authorization": "Bearer \(credential.accessToken)",
            "Accept": "application/json",
            "User-Agent": "Lighthouse",
        ]
        if let account = credential.accountId, !account.isEmpty { headers["ChatGPT-Account-Id"] = account }
        return UsageRequest(url: endpoint, headers: headers)
    }

    /// Accepts only the documented shape: an object with a `rate_limit` object whose present windows
    /// carry a numeric `used_percent`. An empty object, an error object, a missing or non-object
    /// `rate_limit`, or a wrongly typed field is malformed, so it never counts as a success (V-TRUTH).
    /// A null window is a missing window (a weekly-only account has `primary_window` only). A
    /// `rate_limit` with neither `primary_window` nor `secondary_window` key (`{"rate_limit":{}}`), or a
    /// body that yields no window at all, is malformed.
    public func parse(_ body: Data, credential: UsageCredential, now: Date) throws -> UsageSample {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any], object["error"] == nil,
              let rateLimit = try StrictJSON.object(object["rate_limit"]),
              rateLimit.keys.contains("primary_window") || rateLimit.keys.contains("secondary_window") else { throw MalformedUsage() }
        let plan = try StrictJSON.string(object["plan_type"])
        let responseAccount = try StrictJSON.string(object["account_id"])
        var windows: [UsageWindow] = []
        func add(_ value: Any?, pool: String?) throws {
            guard let w = try StrictJSON.object(value) else { return }
            guard let used = try StrictJSON.percent(w["used_percent"]) else { throw MalformedUsage() }
            let duration = try StrictJSON.number(w["limit_window_seconds"])
            let resetAt = try StrictJSON.number(w["reset_at"])
            let resetAfter = try StrictJSON.number(w["reset_after_seconds"])
            let reset = resetAt.map { Date(timeIntervalSince1970: $0) } ?? resetAfter.map { now.addingTimeInterval($0) }
            let kind = Self.kind(duration)
            let id = pool.map { "\($0)-\(kind.id)" } ?? kind.id
            guard !windows.contains(where: { $0.id == id }) else { return }
            windows.append(UsageWindow(id: id, label: pool.map { "\($0) · \(kind.label)" } ?? kind.label,
                                       duration: duration, usedPercent: used, resetsAt: reset))
        }
        try add(rateLimit["primary_window"], pool: nil)
        try add(rateLimit["secondary_window"], pool: nil)
        for extra in try StrictJSON.array(object["additional_rate_limits"]) ?? [] {
            guard let extra = try StrictJSON.object(extra) else { continue }
            guard let name = try StrictJSON.string(extra["limit_name"]), !name.isEmpty,
                  let limit = try StrictJSON.object(extra["rate_limit"]) else { continue }
            try add(limit["primary_window"], pool: name)
            try add(limit["secondary_window"], pool: name)
        }
        // A successful parse yields at least one window.
        guard !windows.isEmpty else { throw MalformedUsage() }
        // The credential's account is the identity; the response's id is used only when auth.json has none,
        // so the two id kinds can never alternate and reset the readings.
        return UsageSample(accountId: credential.accountId ?? responseAccount, plan: plan, windows: windows)
    }

    /// Window id by duration: up to a day is the session window, six days or more is weekly.
    static func kind(_ seconds: Double?) -> (id: String, label: String) {
        guard let seconds else { return (UsageWindow.sessionId, "session") }
        if seconds <= 86400 { return (UsageWindow.sessionId, "session") }
        if seconds >= 6 * 86400 { return (UsageWindow.weeklyId, "week") }
        return ("\(Int(seconds / 3600))h", "\(Int(seconds / 3600)) h")
    }
}

/// Typed reads from `JSONSerialization` output. Absent and null read as nil; any other type throws.
enum StrictJSON {
    static func object(_ value: Any?) throws -> [String: Any]? {
        guard let value, !(value is NSNull) else { return nil }
        guard let object = value as? [String: Any] else { throw MalformedUsage() }
        return object
    }

    static func array(_ value: Any?) throws -> [Any]? {
        guard let value, !(value is NSNull) else { return nil }
        guard let array = value as? [Any] else { throw MalformedUsage() }
        return array
    }

    static func string(_ value: Any?) throws -> String? {
        guard let value, !(value is NSNull) else { return nil }
        guard let string = value as? String else { throw MalformedUsage() }
        return string
    }

    /// A JSON number (not a boolean) that is finite.
    static func number(_ value: Any?) throws -> Double? {
        guard let value, !(value is NSNull) else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else {
            throw MalformedUsage()
        }
        return number.doubleValue
    }

    /// A used percent: a number from 0 to 100 (small overshoot tolerated up to 1000).
    static func percent(_ value: Any?) throws -> Double? {
        guard let number = try number(value) else { return nil }
        guard number >= 0, number <= 1000 else { throw MalformedUsage() }
        return number
    }
}

enum ISODates {
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let lock = NSLock()

    static func parse(_ text: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return fractional.date(from: text) ?? plain.date(from: text)
    }
}

// MARK: Monitor

/// Polls the enabled usage providers. Makes HTTPS GETs only to `UsageEndpoints.allowed`, holds
/// tokens in memory only, never refreshes a token, and never persists or logs a credential.
public actor UsageMonitor {
    public struct Provisioned: Sendable {
        public var adapter: any UsageAdapter
        public var credentials: any UsageCredentialSource
        public init(adapter: any UsageAdapter, credentials: any UsageCredentialSource) {
            self.adapter = adapter
            self.credentials = credentials
        }
    }

    /// SPEC §5.5 poll interval; fresh = 3 intervals.
    public static let defaultPollInterval: TimeInterval = 120
    /// A prompting source (the Keychain) is read at most this often, except on an owner retry.
    public static let promptingRereadInterval: TimeInterval = 600

    private let providers: [Provider: Provisioned]
    private let transport: any UsageTransport
    public private(set) var trackers: [Provider: UsageTracker]
    private var cached: [Provider: UsageCredential] = [:]
    private var lastCredentialRead: [Provider: Date] = [:]
    /// Set after a Keychain denial; cleared only by `retry`.
    private var suspended: Set<Provider> = []
    private var blockedUntil: [Provider: Date] = [:]

    public init(providers: [Provider: Provisioned], transport: any UsageTransport, pollInterval: TimeInterval = UsageMonitor.defaultPollInterval) {
        self.providers = providers
        self.transport = transport
        self.trackers = Dictionary(uniqueKeysWithValues: providers.keys.map { ($0, UsageTracker(provider: $0, pollInterval: pollInterval)) })
    }

    public func readings(now: Date = Date()) -> [ProviderUsage] {
        Provider.allCases.compactMap { provider in
            guard let tracker = trackers[provider], let p = providers[provider] else { return nil }
            return tracker.reading(now: now, source: Self.source(p))
        }
    }

    /// Owner action: forget the cached credential and any suspension, so the next poll reads again.
    public func retry(_ provider: Provider) {
        suspended.remove(provider)
        cached[provider] = nil
        lastCredentialRead[provider] = nil
        blockedUntil[provider] = nil
    }

    /// Owner turned a provider off: drop its token and reading.
    public func disable(_ provider: Provider) {
        retry(provider)
        trackers[provider]?.clear()
    }

    /// One attempt for `provider`. Updates its tracker and returns the new reading.
    @discardableResult
    public func poll(_ provider: Provider, now: Date = Date()) async -> ProviderUsage? {
        guard let p = providers[provider], var tracker = trackers[provider] else { return nil }
        defer { trackers[provider] = tracker }
        // SPEC §5.5: an account change resets the provider's readings before anything is shown, and
        // the token cached for the previous account is dropped so it can never refresh that account.
        let identity = p.credentials.currentAccountId()
        if let account = identity, account != tracker.accountId {
            if let cachedAccount = cached[provider]?.accountId, cachedAccount != account { cached[provider] = nil }
            if tracker.accountId != nil {
                cached[provider] = nil
                lastCredentialRead[provider] = nil
                blockedUntil[provider] = nil
            }
            tracker.observeAccount(account)
        }
        if let until = blockedUntil[provider], until > now {
            tracker.recordFailure(.rateLimited(retryAfter: until), at: now)
            return tracker.reading(now: now, source: Self.source(p))
        }
        let result = await attempt(provider, p, identity: identity, tracker: &tracker, now: now)
        switch result {
        case .success(var sample):
            // The non-prompting identity, when present, is the account; a credential or response
            // label can never move the reading back to another account.
            if let identity { sample.accountId = identity }
            tracker.recordSuccess(sample, at: now)
        case .failure(let failure): tracker.recordFailure(failure, at: now)
        }
        return tracker.reading(now: now, source: Self.source(p))
    }

    static func source(_ p: Provisioned) -> String { "\(p.credentials.location) → \(p.adapter.endpoint.host ?? "")" }

    private func attempt(_ provider: Provider, _ p: Provisioned, identity: String?, tracker: inout UsageTracker,
                         now: Date) async -> Result<UsageSample, UsageFailure> {
        guard let credential = credential(provider, p, now: now) else {
            return .failure(suspended.contains(provider) ? .keychainDenied : lastCredentialFailure[provider] ?? .signInRequired)
        }
        if identity == nil { tracker.observeAccount(credential.accountId) }
        // No refresh in v2.0 (SPEC §4): an expired token is a sign-in, never a stale number as fresh.
        if credential.isExpired(now: now) { return .failure(.signInRequired) }
        let request = p.adapter.request(for: credential)
        guard UsageEndpoints.isAllowed(request.url) else { return .failure(.blockedEndpoint) }
        let response: UsageHTTPResponse
        do {
            response = try await transport.get(request)
        } catch {
            switch error {
            case .offline: return .failure(.networkUnavailable)
            case .timedOut: return .failure(.timedOut)
            case .blocked: return .failure(.blockedEndpoint)
            case .failed: return .failure(.networkUnavailable)
            }
        }
        switch response.status {
        case 200:
            do { return .success(try p.adapter.parse(response.body, credential: credential, now: now)) }
            catch { return .failure(.malformedResponse) }
        case 401, 403:
            // The cached token was rejected; read the source again (rationed for the Keychain).
            cached[provider] = nil
            return .failure(.signInRequired)
        case 429:
            let until = now.addingTimeInterval(min(max(response.retryAfter ?? 300, 60), 3600))
            blockedUntil[provider] = until
            return .failure(.rateLimited(retryAfter: until))
        default:
            return .failure(.server(response.status))
        }
    }

    private var lastCredentialFailure: [Provider: UsageFailure] = [:]

    /// Cached in memory; a file source is read every poll, a prompting source only when the cached
    /// token is missing, expired or rejected, and at most every `promptingRereadInterval`.
    private func credential(_ provider: Provider, _ p: Provisioned, now: Date) -> UsageCredential? {
        if suspended.contains(provider) { return nil }
        if p.credentials.mayPrompt, let token = cached[provider], !token.isExpired(now: now) { return token }
        if p.credentials.mayPrompt, let last = lastCredentialRead[provider], now.timeIntervalSince(last) < Self.promptingRereadInterval {
            return nil
        }
        lastCredentialRead[provider] = now
        switch p.credentials.load() {
        case .found(let token):
            cached[provider] = token
            lastCredentialFailure[provider] = nil
            return token
        case .missing:
            cached[provider] = nil
            lastCredentialFailure[provider] = .signInRequired
        case .denied:
            cached[provider] = nil
            suspended.insert(provider)
            lastCredentialFailure[provider] = .keychainDenied
        case .unreadable:
            cached[provider] = nil
            lastCredentialFailure[provider] = .unreadableCredentials
        }
        return nil
    }
}
