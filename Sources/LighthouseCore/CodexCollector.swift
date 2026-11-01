import Foundation

/// Metadata accumulated from one Codex rollout file. Persisted in its checkpoint (V-PRIV).
public struct CodexFileState: Codable, Sendable, Hashable {
    public var id: String?
    public var cwd: String?
    public var originator: String?
    public var repositoryURL: String?
    public var parentThreadId: String?
    public var agentName: String?
    public var model: String?
    public var startedAt: Date?
    public var lastActivityAt: Date?
    public var lastProgressAt: Date?
    /// true after `task_started`, false after `task_complete`, nil after `turn_aborted` or before any.
    public var turnOpen: Bool?
    /// Time of the latest `task_started` (M4: the stall clock of a running turn starts here).
    public var turnStartedAt: Date?
    /// Local tokens from cumulative `total_token_usage` deltas (SPEC 2.2 §5.5).
    public var tokens: Int
    /// `tokens` by the time of each increment. Required in the stored state, so a checkpoint from
    /// before M2 does not decode and its file is read again from offset 0.
    public var tokenBuckets: TokenBuckets
    public var lastTotalTokens: Int?
    public var tokenEpochs: Int
    /// True when the first total was a mid-file baseline, so `tokens` is partial.
    public var tokensPartial: Bool

    public init() {
        tokens = 0
        tokenBuckets = TokenBuckets()
        tokenEpochs = 0
        tokensPartial = false
    }
}

/// Title index from `session_index.jsonl` (`id` → `thread_name`). Persisted in its checkpoint.
public struct CodexIndexState: Codable, Sendable, Hashable {
    public var titles: [String: String] = [:]
    public init() {}
}

/// Reads Codex sessions from `~/.codex/sessions/**/*.jsonl` and titles from `~/.codex/session_index.jsonl`.
///
/// Fields decoded (Codex 0.154): line `timestamp` and `type`; `session_meta.payload`
/// `id`, `cwd`, `timestamp`, `originator`, `source` (`subagent.thread_spawn.parent_thread_id`,
/// `agent_nickname`, `agent_role`), `git.repository_url`; `event_msg.payload.type` ∈ {`task_started`,
/// `task_complete`, `turn_aborted`, `token_count`, `item_completed`}; `token_count.info.total_token_usage` (cumulative);
/// `turn_context.payload.model`. Message and tool items are never decoded (only their timestamp prefix is
/// read). Codex's SQLite databases are never opened or copied (V-T3DB).
public actor CodexCollector: SessionCollector {
    public nonisolated let kind: SourceKind = .codex
    public nonisolated let sessionsRoot: String
    public nonisolated let indexPath: String
    public nonisolated var watchedPaths: [String] { [sessionsRoot, (indexPath as NSString).deletingLastPathComponent] }

    private let access: SourceAccess
    private let limits: IngestLimits
    private let store: CheckpointStore?
    private var checkpoints: CheckpointSet<CodexFileState>
    private var index: FileCheckpoint<CodexIndexState>?
    static let indexKey = "#session_index"

    public init(codexHome: String = NSHomeDirectory() + "/.codex", access: SourceAccess = ReadOnlyFileSystem(),
                limits: IngestLimits = .standard, store: CheckpointStore? = nil) {
        self.sessionsRoot = (codexHome as NSString).appendingPathComponent("sessions")
        self.indexPath = (codexHome as NSString).appendingPathComponent("session_index.jsonl")
        self.access = access
        self.limits = limits
        self.store = store
        let saved = store?.loadCheckpoints(source: .codex) ?? [:]
        self.checkpoints = CheckpointSet(source: .codex, store: store)
        self.checkpoints.items[Self.indexKey] = nil
        if let stored = saved[Self.indexKey] {
            self.index = FileCheckpoint<CodexIndexState>(stored: stored)
            self.index?.path = self.indexPath
        }
    }

    private var discovery = Discovery()
    private var readTimes = ReadTimes()

    public func restoredThreads(now: Date) -> [SessionThread] {
        Self.assemble(Array(checkpoints.items.values), titles: index?.state.titles ?? [:], readAt: readTimes.sourceReadAt, now: now)
    }

    public func pass(now: Date, scope: PassScope) async -> PassResult {
        let rootCheck = access.checkRoot(sessionsRoot)
        let rootExists = rootCheck == .ok
        let plan: PassPlan<CodexFileState>
        switch scope {
        case .full:
            let listing = rootExists ? access.scan(sessionsRoot, ext: "jsonl", skipping: []) : (files: [], symlinks: 0)
            plan = PassPlan(scanned: listing.files, symlinks: listing.symlinks, checkpoints: checkpoints.items, limits: limits, now: now) { _ in CodexFileState() }
            discovery = plan.discovery
        case .pending:
            plan = PassPlan(pendingFrom: checkpoints.items, discovery: discovery, access: access) { _ in CodexFileState() }
        case .paths(let touched):
            let mine = touched.filter { $0.hasPrefix(sessionsRoot + "/") && $0.hasSuffix(".jsonl") }
            plan = PassPlan(pendingFrom: checkpoints.items, touched: mine, discovery: discovery, access: access) { _ in CodexFileState() }
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
        checkpoints.flush(source: .codex, store: store)
        let (indexBytes, indexMore) = advanceIndex(now: now)
        bytes += indexBytes

        let items = checkpoints.items.values.filter { plan.present.contains($0.path) }
        let threads = Self.assemble(Array(items), titles: index?.state.titles ?? [:], readAt: readTimes.sourceReadAt, now: now)
        let indexed = items.filter { $0.isCaughtUp && !$0.unreadable }.count
        let pending = !discovery.backlog.isEmpty
        let status = CollectorStatus(
            source: .codex, lastReadAt: now, threadCount: threads.count, filesIndexed: indexed,
            filesInWindow: plan.inWindow, filesNotIndexed: plan.notIndexed,
            skippedLines: items.reduce(0) { $0 + $1.skippedLines },
            error: ReadTimes.error(root: rootCheck, rootPath: sessionsRoot, items: Array(items)))
        return PassResult(threads: threads, status: status, bytesRead: bytes, hasMore: pending || indexMore)
    }

    private func advanceIndex(now: Date) -> (Int, Bool) {
        guard let stat = access.stat(indexPath), !stat.isSymlink else { return (0, false) }
        var checkpoint = index ?? FileCheckpoint(path: indexPath, device: stat.device, inode: stat.inode, size: 0, offset: 0,
                                                 mtime: 0, skippedLines: 0, skippingLine: false, state: CodexIndexState())
        if checkpoint.offset == stat.size, checkpoint.inode == stat.inode, checkpoint.device == stat.device { return (0, false) }
        let outcome = JSONLTail.advance(&checkpoint, stat: stat, access: access, limits: limits, now: now,
                                        reset: { $0 = CodexIndexState() },
                                        handle: { line, state in Self.applyIndex(line, to: &state) })
        index = checkpoint
        if var stored = checkpoint.stored {
            stored.path = Self.indexKey
            store?.saveCheckpoints(source: .codex, changed: [stored], removed: [])
        }
        return (outcome.bytesRead, !checkpoint.isCaughtUp)
    }

    static func advance(_ work: FileWork<CodexFileState>, access: SourceAccess, limits: IngestLimits, now: Date) -> FileWork<CodexFileState> {
        var work = work
        let outcome = JSONLTail.advance(&work.checkpoint, stat: work.stat, access: access, limits: limits, now: now,
                                        reset: { $0 = CodexFileState() },
                                        handle: { line, state in apply(line, to: &state) })
        // Files are always read from offset 0 (a checkpoint never starts mid-file), so the first
        // total counts from zero. `fromStart: false` exists for callers that start mid-file.
        work.bytesRead = outcome.bytesRead
        return work
    }

    // MARK: Record handling (static, testable)

    struct Meta: Decodable {
        var payload: Payload
        struct Payload: Decodable {
            var id: String?
            var cwd: String?
            var timestamp: String?
            var originator: String?
            var source: Source?
            var git: Git?

            enum CodingKeys: String, CodingKey { case id, cwd, timestamp, originator, source, git }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                id = try? c.decodeIfPresent(String.self, forKey: .id)
                cwd = try? c.decodeIfPresent(String.self, forKey: .cwd)
                timestamp = try? c.decodeIfPresent(String.self, forKey: .timestamp)
                originator = try? c.decodeIfPresent(String.self, forKey: .originator)
                source = try? c.decodeIfPresent(Source.self, forKey: .source)
                git = try? c.decodeIfPresent(Git.self, forKey: .git)
            }
        }
        struct Git: Decodable { var repository_url: String? }
        /// `source` is a string (`"vscode"`, `"exec"`) or `{"subagent": {"thread_spawn": {...}}}`.
        struct Source: Decodable {
            var parentThreadId: String?
            var agentName: String?

            private struct Sub: Decodable { var subagent: Spawn? }
            private struct Spawn: Decodable { var thread_spawn: ThreadSpawn? }
            private struct ThreadSpawn: Decodable { var parent_thread_id: String?; var agent_nickname: String?; var agent_role: String? }

            init(from decoder: Decoder) throws {
                guard let sub = try? Sub(from: decoder), let spawn = sub.subagent?.thread_spawn else { return }
                parentThreadId = spawn.parent_thread_id
                agentName = spawn.agent_nickname ?? spawn.agent_role
            }
        }
    }

    struct TokenEvent: Decodable {
        var payload: Payload
        struct Payload: Decodable { var info: Info? }
        struct Info: Decodable { var total_token_usage: Usage? }
        struct Usage: Decodable { var total_tokens: Int? }
    }

    struct TurnContext: Decodable {
        var payload: Payload
        struct Payload: Decodable { var model: String? }
    }

    /// Only the line head is scanned to classify a record; message and tool bodies are never decoded.
    static let headBytes = 200

    /// - Parameter fromStart: true when this file is being read from offset 0.
    static func apply(_ line: Data, to state: inout CodexFileState, fromStart: Bool = true) {
        let stamp = LineScan.leadingTimestamp(line)
        if let stamp, stamp > (state.lastActivityAt ?? .distantPast) { state.lastActivityAt = stamp }

        if LineScan.contains(line, "\"type\":\"session_meta\"", within: headBytes) {
            guard let meta = try? JSONDecoder().decode(Meta.self, from: line) else { return }
            let p = meta.payload
            state.id = state.id ?? p.id
            state.cwd = state.cwd ?? p.cwd
            state.originator = state.originator ?? p.originator
            state.repositoryURL = state.repositoryURL ?? p.git?.repository_url
            state.parentThreadId = state.parentThreadId ?? p.source?.parentThreadId
            state.agentName = state.agentName ?? p.source?.agentName
            state.startedAt = state.startedAt ?? Timestamps.parse(p.timestamp) ?? stamp
            return
        }
        if LineScan.contains(line, "\"type\":\"turn_context\"", within: headBytes) {
            if let context = try? JSONDecoder().decode(TurnContext.self, from: line), let model = context.payload.model { state.model = model }
            return
        }
        guard LineScan.contains(line, "\"type\":\"event_msg\"", within: headBytes) else { return }
        if LineScan.contains(line, "\"type\":\"task_started\"", within: headBytes) {
            state.turnOpen = true
            state.turnStartedAt = stamp
        } else if LineScan.contains(line, "\"type\":\"task_complete\"", within: headBytes) {
            state.turnOpen = false
            if let stamp { state.lastProgressAt = stamp }
        } else if LineScan.contains(line, "\"type\":\"turn_aborted\"", within: headBytes) {
            state.turnOpen = nil
        } else if LineScan.contains(line, "\"type\":\"item_completed\"", within: headBytes) {
            if let stamp { state.lastProgressAt = stamp }
        } else if LineScan.contains(line, "\"type\":\"token_count\"", within: headBytes) {
            guard let info = (try? JSONDecoder().decode(TokenEvent.self, from: line))?.payload.info else { return }
            // SPEC 2.3 §5.3: only a positive increase of the cumulative total is progress.
            if let total = info.total_token_usage?.total_tokens,
               applyTotal(total, to: &state, fromStart: fromStart, at: stamp ?? state.lastActivityAt) > 0, let stamp { state.lastProgressAt = stamp }
        }
    }

    /// increment = current − previous; first total counts from zero only when read from offset 0,
    /// otherwise it is a baseline (partial); a decrease starts a new epoch whose total is its first increment.
    /// Returns the increment added (0 for an unchanged total or a baseline).
    @discardableResult
    static func applyTotal(_ total: Int, to state: inout CodexFileState, fromStart: Bool, at stamp: Date? = nil) -> Int {
        var increment = 0
        if let previous = state.lastTotalTokens {
            if total > previous { increment = total - previous }
            else if total < previous { increment = total; state.tokenEpochs += 1 }
        } else if fromStart {
            increment = total
        } else {
            state.tokensPartial = true
        }
        state.tokens += increment
        if let stamp { state.tokenBuckets.add(increment, at: stamp) }
        state.lastTotalTokens = total
        return increment
    }

    static func applyIndex(_ line: Data, to state: inout CodexIndexState) {
        struct Entry: Decodable { var id: String?; var thread_name: String? }
        guard let entry = try? JSONDecoder().decode(Entry.self, from: line), let id = entry.id,
              let name = entry.thread_name, !name.isEmpty else { return }
        state.titles[id] = name
    }

    /// Parents become threads; children (readable `parent_thread_id`) attach to their parent. A child
    /// whose parent is not indexed is not shown as a parent.
    static func assemble(_ items: [FileCheckpoint<CodexFileState>], titles: [String: String],
                         readAt: (FileCheckpoint<CodexFileState>) -> Date, now: Date) -> [SessionThread] {
        var children: [String: [Subagent]] = [:]
        var threads: [SessionThread] = []
        for item in items {
            let s = item.state
            guard let id = s.id, let cwd = s.cwd, let last = s.lastActivityAt else { continue }
            let readTime = readAt(item)
            let state = item.unreadable ? .unknown : StateRules.codex(turnOpen: s.turnOpen, sourceReadAt: readTime, now: now)
            if let parent = s.parentThreadId {
                children[parent, default: []].append(Subagent(
                    id: id, name: s.agentName ?? titles[id] ?? "subagent", model: s.model, provider: .codex, state: state,
                    sourceReadAt: readTime, lastActivityAt: last, lastProgressAt: s.lastProgressAt, tokensTotal: s.tokens > 0 ? s.tokens : nil,
                    tokenBuckets: s.tokenBuckets, tokensPartial: s.tokensPartial))
                children[parent]![children[parent]!.count - 1].startedAt = s.startedAt
                continue
            }
            threads.append(SessionThread(
                id: "codex:\(id)",
                owningApp: s.originator == "T3 Code" ? .t3 : .codex,
                providerIdentities: [ProviderIdentity(provider: .codex, nativeId: id)],
                title: titles[id], cwd: cwd, state: state, startedAt: s.startedAt, sourceReadAt: readTime,
                lastActivityAt: last, lastProgressAt: s.lastProgressAt, tokensTotal: s.tokens > 0 ? s.tokens : nil,
                tokenBuckets: s.tokenBuckets, tokensPartial: s.tokensPartial, originator: s.originator, repositoryURL: s.repositoryURL))
            threads[threads.count - 1].runningSince = s.turnOpen == true ? s.turnStartedAt : nil
            threads[threads.count - 1].transcriptPaths = [item.path]
        }
        return threads.map { thread in
            var thread = thread
            thread.subagents = (children[thread.sessionId] ?? []).sorted { $0.lastActivityAt > $1.lastActivityAt }
            return thread
        }
    }
}
