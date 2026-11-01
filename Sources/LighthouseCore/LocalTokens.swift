import Foundation

/// Local token counts in 5-minute buckets, so a usage window can be attributed (SPEC §5.5).
/// Kept for 8 days after the newest record (longest window: a week). Encoded as a flat
/// `[bucket, tokens, …]` array inside checkpoint state (counters only, V-PRIV).
public struct TokenBuckets: Sendable, Hashable, Codable {
    public static let width: TimeInterval = 300
    public static let retention: TimeInterval = 8 * 86400

    public private(set) var counts: [Int: Int] = [:]

    public init() {}

    public var isEmpty: Bool { counts.isEmpty }
    public var total: Int { counts.values.reduce(0, +) }

    static func bucket(_ date: Date) -> Int { Int((date.timeIntervalSince1970 / width).rounded(.down)) }

    public mutating func add(_ tokens: Int, at date: Date) {
        guard tokens > 0 else { return }
        let key = Self.bucket(date)
        if counts[key] == nil {
            let oldest = Self.bucket(date.addingTimeInterval(-Self.retention))
            counts = counts.filter { $0.key >= oldest }
        }
        counts[key, default: 0] += tokens
    }

    /// The part of `window` made of whole buckets: start rounded up, end rounded down to a bucket edge.
    /// Nil when no whole bucket fits.
    public static func counted(_ window: DateInterval) -> DateInterval? {
        let start = (window.start.timeIntervalSince1970 / width).rounded(.up) * width
        let end = (window.end.timeIntervalSince1970 / width).rounded(.down) * width
        guard end > start else { return nil }
        return DateInterval(start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end))
    }

    /// Tokens in buckets that lie wholly inside `window` (M2-04). Partial edge buckets are excluded,
    /// so nothing before the start or after the end is ever counted; the figure is an undercount by
    /// at most one bucket at each edge and is labelled approximate.
    public func sum(in window: DateInterval) -> Int {
        guard let counted = Self.counted(window) else { return 0 }
        let from = Self.bucket(counted.start), to = Self.bucket(counted.end)   // [from, to) are whole buckets
        return counts.reduce(0) { $1.key >= from && $1.key < to ? $0 + $1.value : $0 }
    }

    public mutating func merge(_ other: TokenBuckets) {
        for (key, value) in other.counts { counts[key, default: 0] += value }
    }

    public init(from decoder: Decoder) throws {
        let flat = try decoder.singleValueContainer().decode([Int].self)
        guard flat.count % 2 == 0 else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "odd bucket list")) }
        for i in stride(from: 0, to: flat.count, by: 2) { counts[flat[i]] = flat[i + 1] }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(counts.keys.sorted().flatMap { [$0, counts[$0]!] })
    }
}

/// One project's local tokens for a provider inside a usage window.
public struct ProjectTokens: Sendable, Hashable, Identifiable {
    public var id: String { project.identity.root }
    public var project: ProjectSummary
    public var tokens: Int
}

/// Local-token attribution for the provider page and thread detail (SPEC §5.5, §6.3). Always shown
/// as "local tokens, not quota share".
public struct LocalTokenAttribution: Sendable, Hashable {
    public var window: DateInterval
    /// The whole 5-minute buckets actually counted inside `window` (nil when none fits).
    public var counted: DateInterval?
    /// True when the window came from the provider's session reset; false for the 5 h fallback.
    public var windowFromProvider: Bool
    public var projects: [ProjectTokens]
    /// Coverage is partial while the provider's collector indexes or reports an error, or when a
    /// counted session started from a mid-file baseline.
    public var partial: Bool

    public static let fallbackDuration: TimeInterval = 5 * 3600

    /// "This window" = [session reset − window duration, now]; if unknown, the last 5 h.
    public static func window(for usage: ProviderUsage?, now: Date) -> (DateInterval, fromProvider: Bool) {
        if let session = usage?.session, let reset = session.resetsAt, let duration = session.duration, reset > now {
            let start = min(reset.addingTimeInterval(-duration), now)
            return (DateInterval(start: start, end: now), true)
        }
        return (DateInterval(start: now.addingTimeInterval(-fallbackDuration), end: now), false)
    }

    /// Tokens of `provider` in `thread` and its subagents. A child's tokens count once, under its
    /// own provider (SPEC §5.2).
    public static func tokens(_ thread: SessionThread, provider: Provider, in window: DateInterval) -> Int {
        var sum = thread.primaryProvider == provider ? thread.tokenBuckets.sum(in: window) : 0
        sum += thread.otherProviderTokens[provider]?.sum(in: window) ?? 0
        for child in thread.subagents {
            if child.provider == provider { sum += child.tokenBuckets.sum(in: window) }
            sum += child.otherProviderTokens[provider]?.sum(in: window) ?? 0
        }
        return sum
    }

    public static func partial(_ thread: SessionThread, provider: Provider) -> Bool {
        (thread.primaryProvider == provider && thread.tokensPartial)
            || thread.subagents.contains { ($0.provider == provider && $0.tokensPartial) || $0.otherProvidersPartial.contains(provider) }
    }

    public init(provider: Provider, usage: ProviderUsage?, projects: [ProjectSummary], statuses: [CollectorStatus], now: Date) {
        let (window, fromProvider) = Self.window(for: usage, now: now)
        self.window = window
        self.counted = TokenBuckets.counted(window)
        self.windowFromProvider = fromProvider
        var partial = false
        var ranked: [ProjectTokens] = []
        for project in projects {
            var sum = 0
            for thread in project.threads {
                let tokens = Self.tokens(thread, provider: provider, in: window)
                if tokens > 0, Self.partial(thread, provider: provider) { partial = true }
                sum += tokens
            }
            if sum > 0 { ranked.append(ProjectTokens(project: project, tokens: sum)) }
        }
        self.projects = ranked.sorted { $0.tokens != $1.tokens ? $0.tokens > $1.tokens : $0.project.identity.name < $1.project.identity.name }
        let source: SourceKind = provider == .claude ? .claudeCode : .codex
        let status = statuses.first { $0.source == source }
        if status == nil || status!.isIndexing || status!.error != nil { partial = true }
        self.partial = partial
    }
}
