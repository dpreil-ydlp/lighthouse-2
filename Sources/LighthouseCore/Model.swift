import Foundation

/// The app that owns a thread. It decides where Open goes (SPEC §5.2, §7), not the model or provider.
public enum OwningApp: String, Codable, Sendable, CaseIterable, Hashable {
    case t3
    case claudeCode
    case codex

    public var chipLabel: String {
        switch self {
        case .t3: "T3"
        case .claudeCode: "Claude"
        case .codex: "Codex"
        }
    }

    public var displayName: String {
        switch self {
        case .t3: "T3 Code"
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }
}

/// The model provider a native session belongs to. Decides usage attribution (M2).
public enum Provider: String, Codable, Sendable, CaseIterable, Hashable {
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}

public struct ProviderIdentity: Sendable, Hashable, Codable {
    public var provider: Provider
    public var nativeId: String

    public init(provider: Provider, nativeId: String) {
        self.provider = provider
        self.nativeId = nativeId
    }
}

/// Observed state (SPEC §5.3).
public enum ThreadState: String, Codable, Sendable, Hashable {
    case running
    case waitingForOwner
    case idle
    case stopped
    case unknown

    /// Expansion order in the shelf: running > waitingForOwner > idle > unknown > stopped (SPEC §6.2).
    public var shelfRank: Int {
        switch self {
        case .running: 0
        case .waitingForOwner: 1
        case .idle: 2
        case .unknown: 3
        case .stopped: 4
        }
    }
}

/// Observe-only child of exactly one thread. Metadata only.
public struct Subagent: Sendable, Hashable, Identifiable, Codable {
    public var id: String
    public var name: String
    public var model: String?
    public var provider: Provider
    public var state: ThreadState
    public var sourceReadAt: Date
    public var lastActivityAt: Date
    public var lastProgressAt: Date?
    public var tokensTotal: Int?
    /// Local tokens by time, for usage-window attribution (SPEC §5.5).
    public var tokenBuckets: TokenBuckets
    public var tokensPartial: Bool
    /// The T3 child thread, when T3 reports this subagent (SPEC §5.2).
    public var t3ThreadId: String?
    /// Native session ids merged into this subagent (T3 child aliases), for usage attribution.
    public var nativeIds: [String]
    /// Pending T3 approval or user-input request of the child thread.
    public var pendingRequest: PendingRequest?
    /// Local tokens of mapped sessions whose provider differs from `provider` (a T3 child that ran
    /// under two providers). Each session still counts once, under its own provider.
    public var otherProviderTokens: [Provider: TokenBuckets] = [:]
    public var otherProvidersPartial: Set<Provider> = []
    /// When the subagent started, if the source says (T3 row, Codex session start).
    public var startedAt: Date?
    /// Start of the oldest tool call T3 shows in flight in the child's current run (M9 F1).
    public var busySince: Date?

    public init(id: String, name: String, model: String? = nil, provider: Provider, state: ThreadState,
                sourceReadAt: Date, lastActivityAt: Date, lastProgressAt: Date? = nil, tokensTotal: Int? = nil,
                tokenBuckets: TokenBuckets = TokenBuckets(), tokensPartial: Bool = false, t3ThreadId: String? = nil,
                nativeIds: [String] = []) {
        self.id = id
        self.name = name
        self.model = model
        self.provider = provider
        self.state = state
        self.sourceReadAt = sourceReadAt
        self.lastActivityAt = lastActivityAt
        self.lastProgressAt = lastProgressAt
        self.tokensTotal = tokensTotal
        self.tokenBuckets = tokenBuckets
        self.tokensPartial = tokensPartial
        self.t3ThreadId = t3ThreadId
        self.nativeIds = nativeIds
    }
}

/// A pending T3 runtime request (SPEC §5.4). Kind only; its text is never read.
public struct PendingRequest: Sendable, Hashable, Codable {
    public var id: String
    public var kind: String
    public var createdAt: Date?

    public init(id: String, kind: String, createdAt: Date?) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
    }

    /// Label shows the request kind only, never its text (SPEC §5.4).
    public var label: String { kind == "user_input" ? "Input requested" : "Approval requested" }
}

/// One canonical parent conversation (SPEC §5.2). No field can hold message text (V-PRIV).
public struct SessionThread: Sendable, Hashable, Identifiable, Codable {
    /// Stable id: `<provider>:<nativeId>` for sessions read from JSONL.
    public var id: String
    public var owningApp: OwningApp
    public var providerIdentities: [ProviderIdentity]
    /// Title from a title field only (§4); never derived from message text.
    public var title: String?
    public var cwd: String
    public var state: ThreadState
    public var startedAt: Date?
    public var sourceReadAt: Date
    public var lastActivityAt: Date
    public var lastProgressAt: Date?
    /// Local tokens summed from usage records (Claude per unique `message.id`, Codex per `last_token_usage`).
    public var tokensTotal: Int?
    /// Local tokens by time, for usage-window attribution (SPEC §5.5).
    public var tokenBuckets: TokenBuckets
    /// True when the session's first token total was a mid-file baseline.
    public var tokensPartial: Bool
    /// Client that wrote the session (Codex `originator`, Claude `entrypoint`).
    public var originator: String?
    public var t3EnvironmentId: String?
    public var t3ThreadId: String?
    public var gitBranch: String?
    public var repositoryURL: String?
    public var subagents: [Subagent]
    /// T3 project workspace root for T3 threads (SPEC §5.1 rule 2), used before the cwd rules.
    public var projectRootHint: String?
    /// Pending T3 approval or user-input request while the thread waits for the owner.
    public var pendingRequest: PendingRequest?
    /// Ids of JSONL sessions merged into this thread as aliases (SPEC §5.2).
    public var aliasIds: [String]
    /// Local tokens of aliases whose provider differs from `primaryProvider` (a T3 thread that
    /// switched provider). Each alias still counts once, under its own provider.
    public var otherProviderTokens: [Provider: TokenBuckets] = [:]
    /// Start of the current running turn (Codex `task_started`, T3 run `requested_at`). No progress is
    /// expected before it, so the stall clock starts no earlier (SPEC §5.4).
    public var runningSince: Date?
    /// False when this thread's progress evidence cannot be observed: a T3 thread with no readable
    /// provider session. Its stall state is "Coverage unknown" (SPEC §5.4).
    public var progressCoverage = true
    /// Start of the oldest tool call T3 shows in flight in the current run (M9 F1). While it is
    /// younger than `AttentionRules.busyCap` the thread is busy, not stalled.
    public var busySince: Date?
    /// JSONL files that back this thread (its own session, or its aliases' for a T3 thread), newest
    /// activity first. Paths only; read solely by the opt-in summary tail reader (SPEC 2.9 §4, M8).
    public var transcriptPaths: [String] = []

    public init(
        id: String,
        owningApp: OwningApp,
        providerIdentities: [ProviderIdentity],
        title: String? = nil,
        cwd: String,
        state: ThreadState,
        startedAt: Date? = nil,
        sourceReadAt: Date,
        lastActivityAt: Date,
        lastProgressAt: Date? = nil,
        tokensTotal: Int? = nil,
        tokenBuckets: TokenBuckets = TokenBuckets(),
        tokensPartial: Bool = false,
        originator: String? = nil,
        t3EnvironmentId: String? = nil,
        t3ThreadId: String? = nil,
        gitBranch: String? = nil,
        repositoryURL: String? = nil,
        subagents: [Subagent] = [],
        projectRootHint: String? = nil,
        pendingRequest: PendingRequest? = nil,
        aliasIds: [String] = []
    ) {
        self.id = id
        self.owningApp = owningApp
        self.providerIdentities = providerIdentities
        self.title = title
        self.cwd = cwd
        self.state = state
        self.startedAt = startedAt
        self.sourceReadAt = sourceReadAt
        self.lastActivityAt = lastActivityAt
        self.lastProgressAt = lastProgressAt
        self.tokensTotal = tokensTotal
        self.tokenBuckets = tokenBuckets
        self.tokensPartial = tokensPartial
        self.originator = originator
        self.t3EnvironmentId = t3EnvironmentId
        self.t3ThreadId = t3ThreadId
        self.gitBranch = gitBranch
        self.repositoryURL = repositoryURL
        self.subagents = subagents
        self.projectRootHint = projectRootHint
        self.pendingRequest = pendingRequest
        self.aliasIds = aliasIds
    }

    /// The native session id Lighthouse copies for app-only opens.
    public var sessionId: String { t3ThreadId ?? providerIdentities.first?.nativeId ?? id }

    public var primaryProvider: Provider? { providerIdentities.first?.provider }

    /// SPEC §5.2 fallback: "Claude Code session · Oct 29 1:04 PM" / "Codex session · …".
    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        let label = primaryProvider == .codex ? "Codex session" : "Claude Code session"
        return "\(label) · \(Self.fallbackFormatter.string(from: startedAt ?? lastActivityAt))"
    }

    private static let fallbackFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d h:mm a"
        return f
    }()

    /// Latest activity of the thread or any of its subagents.
    public var latestActivityAt: Date {
        subagents.map(\.lastActivityAt).reduce(lastActivityAt, max)
    }
}

public enum ProjectKind: String, Codable, Sendable, Hashable {
    case git
    case folder
    case bound
    case t3
    case unassigned
}

/// Stable project identity: the canonical root path (SPEC §5.1).
public struct ProjectIdentity: Sendable, Hashable, Codable, Identifiable {
    public var id: String { root }
    public var root: String
    public var name: String
    public var kind: ProjectKind

    public init(root: String, name: String, kind: ProjectKind) {
        self.root = root
        self.name = name
        self.kind = kind
    }

    public var isUnassigned: Bool { kind == .unassigned }

    /// The folder on disk, or the unassigned cwd.
    public var folderPath: String {
        isUnassigned ? String(root.dropFirst(ProjectResolver.unassignedRoot.count)) : root
    }
}

/// The reader that produced a set of threads.
public enum SourceKind: String, Codable, Sendable, CaseIterable, Hashable {
    case claudeCode
    case codex
    case t3

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code sessions"
        case .codex: "Codex sessions"
        case .t3: "T3 Code"
        }
    }
}

/// Collector health and coverage (SPEC §3.1, §6.6 Sources, §10).
public struct CollectorStatus: Sendable, Hashable, Codable {
    public var source: SourceKind
    public var lastReadAt: Date
    public var threadCount: Int
    /// Files inside the index window that are fully read.
    public var filesIndexed: Int
    /// Files inside the index window.
    public var filesInWindow: Int
    /// Files outside the index window, listed as "not indexed" (never hidden silently).
    public var filesNotIndexed: Int
    public var skippedLines: Int
    public var error: String?

    public init(source: SourceKind, lastReadAt: Date, threadCount: Int, filesIndexed: Int, filesInWindow: Int,
                filesNotIndexed: Int, skippedLines: Int, error: String? = nil) {
        self.source = source
        self.lastReadAt = lastReadAt
        self.threadCount = threadCount
        self.filesIndexed = filesIndexed
        self.filesInWindow = filesInWindow
        self.filesNotIndexed = filesNotIndexed
        self.skippedLines = skippedLines
        self.error = error
    }

    public var isIndexing: Bool { filesIndexed < filesInWindow }
}
