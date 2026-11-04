import Foundation

/// Joins T3 threads with JSONL sessions (SPEC §5.2).
///
/// - A T3 provider-thread row maps native id X to T3 thread T: the JSONL session X is an alias of T.
///   One row, `owningApp = t3`, tokens counted once (from the alias).
/// - A T3 thread that is a child (delegated-task row, or `lineage.relationshipToParent = subagent`)
///   becomes a subagent of its root parent and is never listed as a parent; its JSONL aliases and
///   any JSONL child session with the same native id merge into it.
/// - JSONL sessions without a mapping are unchanged.
/// The T3-only lookups of a merge. They depend on the T3 state alone (not on JSONL sessions or the
/// time), so the engine builds them once per T3 read instead of once per resolve: T3 ids can be long,
/// and hashing them for every row on each resolve is wasted work.
public struct T3MergeIndex: Sendable {
    public let state: T3State
    let threadsById: [String: T3State.Thread]
    let projectsById: [String: T3State.Project]
    let rowsByChild: [String: T3State.SubagentRow]
    /// Top-level parent of every child thread whose parent chain is visible.
    let rootOf: [String: String]
    /// Child thread ids per top-level parent, in T3 thread order.
    let childrenByRoot: [String: [String]]
    /// Threads that are not children of another thread, in T3 thread order.
    let topLevel: [T3State.Thread]
    let t3ByNative: [ProviderIdentity: String]
    let identitiesByThread: [String: [ProviderIdentity]]
    /// The oldest waiting request of each thread whose newest run is active.
    let livePending: [String: PendingRequest]

    public init(_ t3: T3State) {
        state = t3
        let threadsById = Dictionary(t3.threads.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        self.threadsById = threadsById
        projectsById = Dictionary(t3.projects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        rowsByChild = Dictionary(t3.subagents.map { ($0.childThreadId, $0) }, uniquingKeysWith: { a, b in
            (a.updatedAt ?? .distantPast) >= (b.updatedAt ?? .distantPast) ? a : b })

        var parentOf: [String: String] = [:]
        for row in t3.subagents where row.childThreadId != row.parentThreadId { parentOf[row.childThreadId] = row.parentThreadId }
        for thread in t3.threads where parentOf[thread.id] == nil {
            if let parent = thread.lineageParent, parent != thread.id { parentOf[thread.id] = parent }
        }
        /// The top-level parent of a T3 thread; nil when a parent in the chain is not visible (deleted).
        func root(of id: String) -> String? {
            var current = id
            for _ in 0..<16 {
                guard let parent = parentOf[current] else { return threadsById.keys.contains(current) ? current : nil }
                guard threadsById.keys.contains(parent) else { return nil }
                current = parent
            }
            return nil
        }
        var rootOf: [String: String] = [:]
        rootOf.reserveCapacity(parentOf.count)
        for child in parentOf.keys { if let top = root(of: child) { rootOf[child] = top } }
        self.rootOf = rootOf

        var childrenByRoot: [String: [String]] = [:]
        var topLevel: [T3State.Thread] = []
        for thread in t3.threads {
            if let top = rootOf[thread.id] { childrenByRoot[top, default: []].append(thread.id) }
            if parentOf[thread.id] == nil { topLevel.append(thread) }
        }
        self.childrenByRoot = childrenByRoot
        self.topLevel = topLevel

        var t3ByNative: [ProviderIdentity: String] = [:]
        var identitiesByThread: [String: [ProviderIdentity]] = [:]
        for mapping in t3.providerThreads where threadsById[mapping.threadId] != nil {
            let identity = ProviderIdentity(provider: mapping.provider, nativeId: mapping.nativeId)
            t3ByNative[identity] = mapping.threadId
            if !(identitiesByThread[mapping.threadId] ?? []).contains(identity) { identitiesByThread[mapping.threadId, default: []].append(identity) }
        }
        self.t3ByNative = t3ByNative
        self.identitiesByThread = identitiesByThread

        var pendingByThread: [String: PendingRequest] = [:]
        for request in t3.pendingRequests where StateRules.t3WaitingKinds.contains(request.kind) {
            let candidate = PendingRequest(id: request.id, kind: request.kind, createdAt: request.createdAt)
            if let existing = pendingByThread[request.threadId], (existing.createdAt ?? .distantPast) <= (candidate.createdAt ?? .distantPast) { continue }
            pendingByThread[request.threadId] = candidate
        }
        livePending = pendingByThread.filter { id, _ in
            guard let run = t3.runs[id] else { return false }
            return StateRules.t3ActiveRuns.contains(run.status)
        }
    }
}

public enum ThreadMerge {
    public static func merge(jsonl: [SessionThread], t3: T3State?, readAt: Date?, now: Date,
                             window: TimeInterval = IngestLimits.standard.indexWindow) -> [SessionThread] {
        guard let t3, let readAt else { return jsonl }
        return merge(jsonl: jsonl, index: T3MergeIndex(t3), readAt: readAt, now: now, window: window)
    }

    public static func merge(jsonl: [SessionThread], index: T3MergeIndex, readAt: Date, now: Date,
                             window: TimeInterval = IngestLimits.standard.indexWindow) -> [SessionThread] {
        let t3 = index.state
        let threadsById = index.threadsById, projectsById = index.projectsById, rowsByChild = index.rowsByChild
        let rootOf = index.rootOf, t3ByNative = index.t3ByNative, identitiesByThread = index.identitiesByThread
        func livePending(_ id: String) -> PendingRequest? { index.livePending[id] }

        // Route JSONL sessions: aliases of a T3 thread, or kept as they are.
        var aliases: [String: [SessionThread]] = [:]
        var kept: [SessionThread] = []
        for session in jsonl {
            if let t3Id = session.providerIdentities.lazy.compactMap({ t3ByNative[$0] }).first {
                aliases[t3Id, default: []].append(session)
            } else {
                kept.append(session)
            }
        }
        // JSONL child sessions (Codex `thread_spawn`) that T3 also lists as a child thread.
        var jsonlChildren: [ProviderIdentity: Subagent] = [:]
        for session in jsonl {
            for sub in session.subagents where sub.provider == .codex {
                jsonlChildren[ProviderIdentity(provider: .codex, nativeId: sub.id)] = sub
            }
        }
        // JSONL child sessions that a visible T3 child thread claims. They are removed from every
        // JSONL parent, mapped or not, so each child appears and counts once (M3-R02).
        var claimedChildren = Set<String>()
        for (identity, kid) in jsonlChildren {
            if let t3Id = t3ByNative[identity], rootOf[t3Id] != nil { claimedChildren.insert(kid.id) }
        }
        kept = kept.map { session in
            var session = session
            session.subagents.removeAll { $0.provider == .codex && claimedChildren.contains($0.id) }
            return session
        }

        func subagent(child id: String) -> Subagent? {
            guard let thread = threadsById[id] else { return nil }
            let row = rowsByChild[id]
            let childAliases = aliases[id] ?? []
            let identities = identitiesByThread[id] ?? []
            let jsonlKids = identities.compactMap { jsonlChildren[$0] }
            let provider = T3Reader.provider(row?.provider) ?? childAliases.first?.primaryProvider ?? identities.first?.provider ?? .claude
            let pending = livePending(id)
            let run = t3.runs[id]
            let state: ThreadState = row.map { StateRules.t3Subagent(status: $0.status, childWaiting: pending != nil, sourceReadAt: readAt, now: now) }
                ?? StateRules.t3Thread(runStatus: run?.status, pending: pending, archived: thread.archived, sourceReadAt: readAt, now: now)
            var otherPartial = Set<Provider>()
            // Each mapped session counts once, under its own provider (M3-R03): the subagent's provider
            // keeps `tokenBuckets`; a session of another provider goes to `otherProviderTokens`.
            var buckets = TokenBuckets()
            var other: [Provider: TokenBuckets] = [:]
            var tokens = 0
            var partial = false
            var counted = Set<ProviderIdentity>()
            let sources: [(ProviderIdentity?, Provider?, TokenBuckets, Int?, Bool)] =
                childAliases.map { ($0.providerIdentities.first, $0.primaryProvider, $0.tokenBuckets, $0.tokensTotal, $0.tokensPartial) }
                + jsonlKids.map { (ProviderIdentity(provider: $0.provider, nativeId: $0.id), $0.provider, $0.tokenBuckets, $0.tokensTotal, $0.tokensPartial) }
            for (identity, sourceProvider, sourceBuckets, total, sourcePartial) in sources {
                guard let sourceProvider else { continue }
                if let identity, !counted.insert(identity).inserted { continue }
                if sourceProvider == provider {
                    buckets.merge(sourceBuckets)
                    tokens += total ?? 0
                    partial = partial || sourcePartial
                } else {
                    other[sourceProvider, default: TokenBuckets()].merge(sourceBuckets)
                    if sourcePartial { otherPartial.insert(sourceProvider) }
                }
            }
            let activity = latest([row?.updatedAt, row?.startedAt, run?.requestedAt, run?.completedAt, thread.createdAt]
                                  + childAliases.map(\.latestActivityAt) + jsonlKids.map(\.lastActivityAt))
            let progress = latest([row?.completedAt, run?.lastCompletedAt] + childAliases.map(\.lastProgressAt) + jsonlKids.map(\.lastProgressAt))
            var sub = Subagent(id: "t3:\(id)", name: thread.title.isEmpty ? "subagent" : thread.title, provider: provider, state: state,
                               sourceReadAt: readAt, lastActivityAt: activity ?? readAt, lastProgressAt: progress,
                               tokensTotal: tokens > 0 ? tokens : nil, tokenBuckets: buckets, tokensPartial: partial, t3ThreadId: id,
                               nativeIds: Array(Set(identities.map(\.nativeId) + childAliases.flatMap { $0.providerIdentities.map(\.nativeId) })).sorted())
            sub.otherProviderTokens = other
            sub.otherProvidersPartial = otherPartial
            sub.model = jsonlKids.first?.model ?? childAliases.first?.subagents.first?.model
            sub.startedAt = row?.startedAt ?? run?.requestedAt
            if state == .running { sub.busySince = t3.busySince[id] }
            if state == .waitingForOwner { sub.pendingRequest = pending }
            return sub
        }

        let childrenByRoot = index.childrenByRoot

        var merged: [SessionThread] = []
        for thread in index.topLevel {
            let own = (aliases[thread.id] ?? []).sorted { $0.latestActivityAt > $1.latestActivityAt }
            let project = projectsById[thread.projectId]
            guard let cwd = thread.worktreePath ?? project?.root ?? own.first?.cwd else { continue }
            var identities = own.flatMap(\.providerIdentities)
            for identity in identitiesByThread[thread.id] ?? [] where !identities.contains(identity) { identities.append(identity) }
            var unique: [ProviderIdentity] = []
            for identity in identities where !unique.contains(identity) { unique.append(identity) }
            let primary = unique.first?.provider

            let run = t3.runs[thread.id]
            let pending = livePending(thread.id)
            let state = StateRules.t3Thread(runStatus: run?.status, pending: pending, archived: thread.archived, sourceReadAt: readAt, now: now)

            var subagents = (childrenByRoot[thread.id] ?? []).compactMap(subagent(child:))
            // Children of the aliases (Claude `subagents/` files, Codex spawns) and of the T3 children's aliases.
            let childAliasKids = (childrenByRoot[thread.id] ?? []).flatMap { aliases[$0] ?? [] }.flatMap(\.subagents)
            for kid in own.flatMap(\.subagents) + childAliasKids where !claimedChildren.contains(kid.id) {
                subagents.append(kid)
            }
            subagents = sortedByActivity(subagents)

            var buckets = TokenBuckets()
            var other: [Provider: TokenBuckets] = [:]
            var tokens = 0
            var partial = false
            for alias in own {
                guard let provider = alias.primaryProvider else { continue }
                if provider == primary {
                    buckets.merge(alias.tokenBuckets)
                    tokens += alias.tokensTotal ?? 0
                    partial = partial || alias.tokensPartial
                } else {
                    other[provider, default: TokenBuckets()].merge(alias.tokenBuckets)
                }
            }
            let activity = latest([run?.requestedAt, run?.completedAt, thread.createdAt] + own.map(\.lastActivityAt)) ?? readAt
            let progress = latest([run?.lastCompletedAt] + own.map(\.lastProgressAt))
            var result = SessionThread(
                id: "t3:\(thread.id)", owningApp: .t3, providerIdentities: unique,
                title: thread.title.isEmpty ? own.first?.title : thread.title, cwd: cwd, state: state,
                startedAt: thread.createdAt ?? own.last?.startedAt, sourceReadAt: readAt, lastActivityAt: activity, lastProgressAt: progress,
                tokensTotal: tokens > 0 ? tokens : nil, tokenBuckets: buckets, tokensPartial: partial, originator: "T3 Code",
                t3EnvironmentId: t3.environmentId, t3ThreadId: thread.id, gitBranch: own.first?.gitBranch,
                repositoryURL: own.first?.repositoryURL, subagents: subagents, projectRootHint: project?.root,
                pendingRequest: state == .waitingForOwner ? pending : nil, aliasIds: own.map(\.id))
            result.otherProviderTokens = other
            result.settledAt = thread.settledAt
            // The provider transcripts that back this T3 thread (M8 summaries), newest alias first.
            result.transcriptPaths = own.flatMap(\.transcriptPaths)
            if let run, StateRules.t3ActiveRuns.contains(run.status) {
                result.runningSince = run.requestedAt
                result.busySince = t3.busySince[thread.id]
            }
            // T3 records no progress inside a run; evidence comes from its provider sessions (§5.3),
            // and only while one of them is read fresh (an unreadable mapped rollout is no evidence, M4-R05).
            result.progressCoverage = own.contains { now.timeIntervalSince($0.sourceReadAt) <= StateRules.sourceStaleAfter }
            let live = state == .running || state == .waitingForOwner || subagents.contains { $0.state == .running || $0.state == .waitingForOwner }
            guard live || now.timeIntervalSince(result.latestActivityAt) <= window else { continue }
            merged.append(result)
        }
        return kept + merged
    }

    private static func latest(_ dates: [Date?]) -> Date? { dates.compactMap { $0 }.max() }

    /// Newest activity first; ties keep their input order (what the stable `sort` gave). Sorts
    /// indices, so each large `Subagent` value moves once (a parent can hold many).
    static func sortedByActivity(_ subagents: [Subagent]) -> [Subagent] {
        let keys = subagents.map(\.lastActivityAt)
        let order = keys.indices.sorted { keys[$0] > keys[$1] || (keys[$0] == keys[$1] && $0 < $1) }
        return order.map { subagents[$0] }
    }
}
