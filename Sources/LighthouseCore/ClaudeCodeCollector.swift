import Foundation

/// Metadata accumulated from one Claude Code JSONL file. Persisted in its checkpoint. Every field is
/// an id, path, title-field value, timestamp, counter, or flag (V-PRIV).
public struct ClaudeFileState: Codable, Sendable, Hashable {
    public var sessionId: String?
    public var agentId: String?
    /// True for files under `<session>/subagents/`. A child is never listed as a parent.
    public var isChild: Bool
    public var agentType: String?
    public var model: String?
    public var cwd: String?
    public var gitBranch: String?
    public var entrypoint: String?
    public var startedAt: Date?
    public var lastActivityAt: Date?
    public var lastProgressAt: Date?
    public var lastTurnRecordAt: Date?
    /// Kind of the last user/assistant record (SPEC 2.2 §5.3).
    public var lastTurnKind: ClaudeTurnKind?
    public var summaryTitle: String?
    public var customTitle: String?
    public var tokens: Int
    /// `tokens` by time. Required in the stored state, so a checkpoint from before M2 does not decode
    /// and its file is read again from offset 0 to rebuild the buckets.
    public var tokenBuckets: TokenBuckets
    /// Recent `message.id`s already counted, so split assistant records count once.
    public var recentMessageIds: [String]

    public init(isChild: Bool) {
        self.isChild = isChild
        self.tokens = 0
        self.tokenBuckets = TokenBuckets()
        self.recentMessageIds = []
    }
}

public enum ClaudeTurnKind: String, Codable, Sendable, Hashable {
    case userOrToolResult
    case assistantEndTurn
    case assistantOther
}

/// Reads Claude Code sessions from `~/.claude/projects/**/*.jsonl` (SPEC §4).
///
/// Fields decoded (Claude Code 2.x): `type`, `sessionId`, `agentId`, `cwd`,
/// `timestamp`, `gitBranch`, `entrypoint`; `message.id`, `message.stop_reason`, `message.usage`
/// counters; `summary` (type `summary`) and `customTitle` (type `custom-title`) title fields.
/// `message.content` and every other text field are not declared, so they are never decoded.
/// Child metadata (`agentType`, `model`) comes from `subagents/agent-<id>.meta.json`.
public actor ClaudeCodeCollector: SessionCollector {
    public nonisolated let kind: SourceKind = .claudeCode
    public nonisolated let root: String
    public nonisolated var watchedPaths: [String] { [root] }

    private let access: SourceAccess
    private let limits: IngestLimits
    private let store: CheckpointStore?
    private var checkpoints: CheckpointSet<ClaudeFileState>
    private var lastError: String?

    public init(root: String = NSHomeDirectory() + "/.claude/projects", access: SourceAccess = ReadOnlyFileSystem(),
                limits: IngestLimits = .standard, store: CheckpointStore? = nil) {
        self.root = root
        self.access = access
        self.limits = limits
        self.store = store
        self.checkpoints = CheckpointSet(source: .claudeCode, store: store)
    }

    /// Folders Claude Code keeps beside sessions that never hold session logs (tool output, memory).
    static let nonSessionFolders: Set<String> = ["tool-results", "memory", "file-history"]

    static func isChildPath(_ path: String) -> Bool {
        (path as NSString).deletingLastPathComponent.hasSuffix("/subagents")
    }

    private var discovery = Discovery()
    private var readTimes = ReadTimes()

    public func restoredThreads(now: Date) -> [SessionThread] {
        Self.assemble(Array(checkpoints.items.values), readAt: readTimes.sourceReadAt, now: now)
    }

    public func pass(now: Date, scope: PassScope) async -> PassResult {
        let rootCheck = access.checkRoot(root)
        let rootExists = rootCheck == .ok
        let plan: PassPlan<ClaudeFileState>
        switch scope {
        case .full:
            let listing = rootExists ? access.scan(root, ext: "jsonl", skipping: Self.nonSessionFolders) : (files: [], symlinks: 0)
            plan = PassPlan(scanned: listing.files, symlinks: listing.symlinks, checkpoints: checkpoints.items, limits: limits, now: now) { ClaudeFileState(isChild: Self.isChildPath($0)) }
            discovery = plan.discovery
        case .pending:
            plan = PassPlan(pendingFrom: checkpoints.items, discovery: discovery, access: access) { ClaudeFileState(isChild: Self.isChildPath($0)) }
        case .paths(let touched):
            let mine = touched.filter { $0.hasPrefix(root + "/") && $0.hasSuffix(".jsonl") }
            plan = PassPlan(pendingFrom: checkpoints.items, touched: mine, discovery: discovery, access: access) { ClaudeFileState(isChild: Self.isChildPath($0)) }
            discovery = plan.discovery
        }
        let access = self.access, limits = self.limits
        let done = ParallelMap.run(plan.work) { work in Self.advance(work, access: access, limits: limits, now: now) }
        var bytes = 0
        for work in done {
            checkpoints.update(work.checkpoint)
            discovery.settle(work.checkpoint)
            bytes += work.bytesRead
        }
        readTimes.record(plan: plan, done: done, now: now)
        if scope == .full { checkpoints.drop(missingFrom: plan.present) }
        checkpoints.flush(source: .claudeCode, store: store)

        let items = checkpoints.items.values.filter { plan.present.contains($0.path) }
        let threads = Self.assemble(Array(items), readAt: readTimes.sourceReadAt, now: now)
        let indexed = items.filter { $0.isCaughtUp && !$0.unreadable }.count
        let pending = !discovery.backlog.isEmpty
        let status = CollectorStatus(
            source: .claudeCode, lastReadAt: now, threadCount: threads.count, filesIndexed: indexed,
            filesInWindow: plan.inWindow, filesNotIndexed: plan.notIndexed,
            skippedLines: items.reduce(0) { $0 + $1.skippedLines },
            error: ReadTimes.error(root: rootCheck, rootPath: root, items: Array(items)))
        return PassResult(threads: threads, status: status, bytesRead: bytes, hasMore: pending)
    }

    static func advance(_ work: FileWork<ClaudeFileState>, access: SourceAccess, limits: IngestLimits, now: Date) -> FileWork<ClaudeFileState> {
        var work = work
        let outcome = JSONLTail.advance(&work.checkpoint, stat: work.stat, access: access, limits: limits, now: now,
                                        reset: { $0 = ClaudeFileState(isChild: $0.isChild) },
                                        handle: { line, state in apply(line, to: &state) })
        work.bytesRead = outcome.bytesRead
        if work.checkpoint.state.isChild, work.checkpoint.state.agentType == nil {
            loadMeta(for: work.path, into: &work.checkpoint.state, access: access)
        }
        return work
    }

    // MARK: Record handling (static, testable)

    struct Record: Decodable {
        var type: String?
        var sessionId: String?
        var agentId: String?
        var cwd: String?
        var timestamp: String?
        var gitBranch: String?
        var entrypoint: String?
        var summary: String?
        var customTitle: String?
        var message: Message?

        struct Message: Decodable {
            var id: String?
            var role: String?
            var stop_reason: String?
            var usage: Usage?

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                id = try? c.decodeIfPresent(String.self, forKey: .id)
                role = try? c.decodeIfPresent(String.self, forKey: .role)
                stop_reason = try? c.decodeIfPresent(String.self, forKey: .stop_reason)
                usage = try? c.decodeIfPresent(Usage.self, forKey: .usage)
            }

            enum CodingKeys: String, CodingKey { case id, role, stop_reason, usage }
        }

        struct Usage: Decodable {
            var input_tokens: Int?
            var output_tokens: Int?
            var cache_read_input_tokens: Int?
            var cache_creation_input_tokens: Int?

            var total: Int { (input_tokens ?? 0) + (output_tokens ?? 0) + (cache_read_input_tokens ?? 0) + (cache_creation_input_tokens ?? 0) }
        }

        enum CodingKeys: String, CodingKey { case type, sessionId, agentId, cwd, timestamp, gitBranch, entrypoint, summary, customTitle, message }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try? c.decodeIfPresent(String.self, forKey: .type)
            sessionId = try? c.decodeIfPresent(String.self, forKey: .sessionId)
            agentId = try? c.decodeIfPresent(String.self, forKey: .agentId)
            cwd = try? c.decodeIfPresent(String.self, forKey: .cwd)
            timestamp = try? c.decodeIfPresent(String.self, forKey: .timestamp)
            gitBranch = try? c.decodeIfPresent(String.self, forKey: .gitBranch)
            entrypoint = try? c.decodeIfPresent(String.self, forKey: .entrypoint)
            // Title fields are read only from their own record types.
            if type == "summary" { summary = try? c.decodeIfPresent(String.self, forKey: .summary) }
            if type == "custom-title" { customTitle = try? c.decodeIfPresent(String.self, forKey: .customTitle) }
            if type == "assistant" || type == "user" { message = try? c.decodeIfPresent(Message.self, forKey: .message) }
        }
    }

    static func apply(_ line: Data, to state: inout ClaudeFileState) {
        // Decode only record types §4 uses. Request blobs, attachments and progress records are skipped
        // unread; content blocks never use these type values.
        guard LineScan.contains(line, "\"type\":\"user\"") || LineScan.contains(line, "\"type\":\"assistant\"")
            || LineScan.contains(line, "\"type\":\"summary\"") || LineScan.contains(line, "\"type\":\"custom-title\"") else { return }
        guard let record = try? JSONDecoder().decode(Record.self, from: line) else { return }
        if state.sessionId == nil, let id = record.sessionId { state.sessionId = id }
        if state.agentId == nil, let id = record.agentId { state.agentId = id }
        if state.cwd == nil, let cwd = record.cwd, !cwd.isEmpty { state.cwd = cwd }
        if let branch = record.gitBranch, !branch.isEmpty { state.gitBranch = branch }
        if state.entrypoint == nil { state.entrypoint = record.entrypoint }
        if let title = record.summary, !title.isEmpty { state.summaryTitle = title }
        if let title = record.customTitle, !title.isEmpty { state.customTitle = title }

        guard let stamp = Timestamps.parse(record.timestamp) else { return }
        if state.startedAt == nil { state.startedAt = stamp }
        if stamp > (state.lastActivityAt ?? .distantPast) { state.lastActivityAt = stamp }

        switch record.type {
        case "user":
            // A user or tool-result record means the agent owes a reply.
            state.lastTurnKind = .userOrToolResult
            state.lastTurnRecordAt = stamp
        case "assistant":
            state.lastTurnKind = record.message?.stop_reason == "end_turn" ? .assistantEndTurn : .assistantOther
            state.lastTurnRecordAt = stamp
            if let id = record.message?.id, !state.recentMessageIds.contains(id) {
                state.recentMessageIds.append(id)
                if state.recentMessageIds.count > 32 { state.recentMessageIds.removeFirst() }
                let tokens = record.message?.usage?.total ?? 0
                state.tokens += tokens
                state.tokenBuckets.add(tokens, at: stamp)
                state.lastProgressAt = stamp
            }
        default:
            break
        }
    }

    static func loadMeta(for logPath: String, into state: inout ClaudeFileState, access: SourceAccess) {
        let metaPath = (logPath as NSString).deletingPathExtension + ".meta.json"
        guard let stat = access.stat(metaPath), !stat.isSymlink, stat.size < 64 << 10,
              let data = access.read(metaPath, offset: 0, count: Int(stat.size)) else { return }
        struct Meta: Decodable { var agentType: String?; var model: String? }
        guard let meta = try? JSONDecoder().decode(Meta.self, from: data) else { return }
        state.agentType = meta.agentType ?? "subagent"
        state.model = meta.model
    }

    /// Builds parent threads and attaches children by `sessionId` (or the session folder name).
    /// Unreadable files keep their last known metadata but show `unknown` and their last good read
    /// time (SPEC §2 V-TRUTH, §5.3).
    static func assemble(_ items: [FileCheckpoint<ClaudeFileState>], readAt: (FileCheckpoint<ClaudeFileState>) -> Date, now: Date) -> [SessionThread] {
        var children: [String: [Subagent]] = [:]
        var threads: [SessionThread] = []
        for item in items {
            let s = item.state
            guard let last = s.lastActivityAt else { continue }
            let readTime = readAt(item)
            let state = item.unreadable ? .unknown
                : StateRules.claude(lastTurnKind: s.lastTurnKind, lastTurnRecordAt: s.lastTurnRecordAt, sourceReadAt: readTime, now: now)
            if s.isChild {
                let parent = s.sessionId ?? (((item.path as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent as NSString).lastPathComponent
                let fileId = String(((item.path as NSString).lastPathComponent as NSString).deletingPathExtension.dropFirst("agent-".count))
                children[parent, default: []].append(Subagent(
                    id: s.agentId ?? fileId, name: s.agentType ?? "subagent", model: s.model, provider: .claude, state: state,
                    sourceReadAt: readTime, lastActivityAt: last, lastProgressAt: s.lastProgressAt, tokensTotal: s.tokens > 0 ? s.tokens : nil,
                    tokenBuckets: s.tokenBuckets))
                continue
            }
            guard let cwd = s.cwd else { continue }
            let sessionId = s.sessionId ?? ((item.path as NSString).lastPathComponent as NSString).deletingPathExtension
            threads.append(SessionThread(
                id: "claude:\(sessionId)", owningApp: .claudeCode,
                providerIdentities: [ProviderIdentity(provider: .claude, nativeId: sessionId)],
                title: s.customTitle ?? s.summaryTitle, cwd: cwd, state: state, startedAt: s.startedAt,
                sourceReadAt: readTime, lastActivityAt: last, lastProgressAt: s.lastProgressAt,
                tokensTotal: s.tokens > 0 ? s.tokens : nil, tokenBuckets: s.tokenBuckets, originator: s.entrypoint, gitBranch: s.gitBranch))
            threads[threads.count - 1].transcriptPaths = [item.path]
        }
        return threads.map { thread in
            var thread = thread
            thread.subagents = (children[thread.sessionId] ?? []).sorted { $0.lastActivityAt > $1.lastActivityAt }
            return thread
        }
    }
}
