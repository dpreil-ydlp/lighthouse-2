import Foundation

/// One observed state of the world, handed to the UI.
public struct Snapshot: Sendable {
    public var projects: [ProjectSummary]
    public var statuses: [CollectorStatus]
    public var checkedAt: Date?
    /// True while any collector still has unread bytes inside its index window.
    public var indexing: Bool
    /// T3 unreadable after a good read (M9 F4); nil while T3 reads, or if it never read.
    public var t3Outage: SourceOutage?

    public init(projects: [ProjectSummary], statuses: [CollectorStatus], checkedAt: Date?, indexing: Bool) {
        self.projects = projects
        self.statuses = statuses
        self.checkedAt = checkedAt
        self.indexing = indexing
    }

    public static let empty = Snapshot(projects: [], statuses: [], checkedAt: nil, indexing: true)
}

/// Runs collector passes, resolves projects, and persists checkpoints and status. Makes no network calls.
public actor Engine {
    public let collectors: [any SessionCollector]
    public let store: Store?
    private let home: String
    private let projectsRoots: [String]?
    public let t3: T3Collector?
    public private(set) var bytesReadTotal = 0
    /// Increments whenever a pass read new JSONL bytes or T3 data (or its error line) changed.
    public private(set) var changeCount = 0

    /// - Parameter t3NotRead: why there is no T3 source (scratch test mode). It is shown as the T3
    ///   status line, so a run without T3 never passes for one with T3 (M4-R08: without it, T3-owned
    ///   Codex sessions showed fallback titles and unnested delegated tasks with no hint why).
    public init(collectors: [any SessionCollector], store: Store?, home: String = NSHomeDirectory(), projectsRoots: [String]? = nil,
                t3: T3Collector? = nil, t3NotRead: String? = nil) {
        self.collectors = collectors
        self.store = store
        self.home = home
        self.projectsRoots = projectsRoots
        self.t3 = t3
        self.t3NotRead = t3 == nil ? t3NotRead : nil
        // The last good T3 read of an earlier run (M9 F4). A T3 row with `filesIndexed == 1` carries it.
        if let row = (try? store?.loadStatuses())?.first(where: { $0.source == .t3 }), row.filesIndexed == 1 {
            t3LastSuccess = row.lastReadAt
        }
    }

    /// Last good T3 read, this run or (from `collector_status`) an earlier one, and the first failed
    /// attempt since it in this run (M9 F4).
    private var t3LastSuccess: Date?
    private var t3FailingSince: Date?

    private let t3NotRead: String?

    public static func live(store: Store?) -> Engine {
        Engine(collectors: [ClaudeCodeCollector(store: store), CodexCollector(store: store)], store: store, t3: T3Collector())
    }

    /// Last successful T3 read (in memory only) and its time.
    private var t3State: T3State?
    /// Merge lookups of `t3State`, rebuilt only when a T3 read changed it (M7).
    private var t3Index: T3MergeIndex?
    private var t3ReadAt: Date?
    private var t3Status: CollectorStatus?

    public nonisolated var watchedPaths: [String] { collectors.flatMap(\.watchedPaths) }

    /// One bounded pass over every collector (SPEC §3.1).
    private var lastThreads: [SessionThread] = []
    private var lastStatuses: [CollectorStatus] = []
    private var lastIndexing = false

    /// The last known shelf from stored checkpoints, without reading any source file. Threads whose
    /// last successful read is older than the stale bound show `unknown` (SPEC §5.3), so nothing
    /// restored looks fresh. `checkedAt` is nil: no source has been read in this run yet.
    public func restoredSnapshot(now: Date = Date()) async -> Snapshot {
        var threads: [SessionThread] = []
        for collector in collectors { threads += await collector.restoredThreads(now: now) }
        let statuses = (try? store?.loadStatuses()) ?? []
        var snapshot = self.snapshot(threads: threads, statuses: statuses, now: now, indexing: true, observe: false)
        snapshot.checkedAt = nil
        return snapshot
    }

    /// Resolves the threads from the last pass into a snapshot (used when a pass skipped resolution).
    public func resolvedSnapshot(now: Date = Date()) -> Snapshot {
        snapshot(threads: lastThreads, statuses: lastStatuses, now: now, indexing: lastIndexing)
    }

    public func pass(now: Date = Date(), scope: PassScope = .full, resolve: Bool = true) async -> Snapshot {
        observation.notePass(at: now)
        var threads: [SessionThread] = []
        var statuses: [CollectorStatus] = []
        var indexing = false
        for collector in collectors {
            let result = await collector.pass(now: now, scope: scope)
            threads += result.threads
            statuses.append(result.status)
            bytesReadTotal += result.bytesRead
            if result.bytesRead > 0 { changeCount += 1 }
            indexing = indexing || result.hasMore
        }
        // Catch-up passes during indexing skip T3; full and FSEvents passes poll it (throttled).
        if let t3, scope != .pending {
            let result = await t3.pass(now: now)
            // A pass that read nothing new returns the same state with `changed` false.
            if result.changed || (t3Index == nil) != (result.state == nil) { t3Index = result.state.map(T3MergeIndex.init) }
            t3State = result.state
            t3ReadAt = result.readAt
            t3Status = result.status
            if result.changed { changeCount += 1 }
            if let readAt = result.readAt { t3LastSuccess = max(t3LastSuccess ?? readAt, readAt) }
            if result.status.error == nil {
                t3FailingSince = nil
            } else if t3FailingSince == nil {
                t3FailingSince = now
            }
            // The stored T3 row keeps the last good read, also after a restart during an outage, so
            // "Last read" stays truthful and the outage keeps its identity (M9 F4).
            if t3Status?.error != nil, let last = t3LastSuccess {
                t3Status?.lastReadAt = last
                t3Status?.filesIndexed = 1
                t3Status?.filesInWindow = 1
            }
        }
        if let t3Status { statuses.append(t3Status) }
        if let t3NotRead {
            statuses.append(CollectorStatus(source: .t3, lastReadAt: now, threadCount: 0, filesIndexed: 0, filesInWindow: 0,
                                            filesNotIndexed: 0, skippedLines: 0, error: t3NotRead))
        }
        try? store?.saveStatuses(statuses)
        lastThreads = threads
        lastStatuses = statuses
        lastIndexing = indexing
        guard resolve else {
            var bare = Snapshot(projects: [], statuses: statuses, checkedAt: now, indexing: indexing)
            bare.t3Outage = t3Outage
            return bare
        }
        return snapshot(threads: threads, statuses: statuses, now: now, indexing: indexing)
    }

    /// T3 is failing after a good read (M9 F4). "Database not found" is absence, not an outage.
    var t3Outage: SourceOutage? {
        guard let since = t3FailingSince, let last = t3LastSuccess, let error = t3Status?.error,
              error != T3ReadError.notFound.description else { return nil }
        return SourceOutage(source: .t3, lastSuccess: last, failingSince: since)
    }

    private var resolver: ProjectResolver?
    private var resolverBindings: [ProjectBinding] = []
    private var resolverBuiltAt = Date.distantPast
    private var resolverT3: [String: String] = [:]
    /// Gap-free observation per subject, for stall and silence timing (SPEC §5.4, M4).
    private var observation = ObservationTracker()
    /// "Waiting on you" from the last agent message of finished threads (SPEC 2.10).
    private var replies = ReplyScanner()

    /// Resolution results are cached; the cache is rebuilt when bindings or T3 projects change, or every 60 s.
    /// `observe` is false for the restored launch shelf, which is not an observation: nothing in it
    /// has been observed yet, so it raises no stall or silence (M9 R1: at relaunch it was built before
    /// any T3 read, so a T3 thread's alias looked like a stalled Codex thread and was notified).
    func snapshot(threads jsonl: [SessionThread], statuses: [CollectorStatus], now: Date, indexing: Bool, observe: Bool = true) -> Snapshot {
        var threads = if let t3Index, let t3ReadAt { ThreadMerge.merge(jsonl: jsonl, index: t3Index, readAt: t3ReadAt, now: now) } else { jsonl }
        // The restored launch shelf reads no source file, so it raises no reply wait either.
        if observe { threads = replies.mark(threads, now: now) }
        let unobserved: ObservedSince = { _ in now }
        let observedSince = observe ? observation.observe(threads, now: now) : unobserved
        let bindings = (try? store?.loadBindings()) ?? []
        let t3Projects = Dictionary((t3State?.projects ?? []).map { ($0.root, $0.title) }, uniquingKeysWith: { a, _ in a })
        if resolver == nil || bindings != resolverBindings || t3Projects != resolverT3 || now.timeIntervalSince(resolverBuiltAt) > 60 {
            resolver = ProjectResolver(home: home, projectsRoots: projectsRoots, bindings: bindings,
                                       t3Roots: Array(t3Projects.keys), t3Titles: t3Projects)
            resolverBindings = bindings
            resolverT3 = t3Projects
            resolverBuiltAt = now
        }
        let resolver = self.resolver!
        var identities = resolver.resolveAll(threads.map { ($0.cwd, $0.repositoryURL) })
        // SPEC §5.1: an explicit binding wins; otherwise a T3 thread belongs to its T3 project.
        for (index, thread) in threads.enumerated() where identities[index].kind != .bound {
            if let hint = thread.projectRootHint { identities[index] = resolver.resolve(cwd: hint) }
        }
        let acknowledged = (try? store?.loadAcknowledgements()) ?? []
        let projects = ShelfBuilder.summarize(threads: threads, identities: identities, acknowledged: acknowledged, now: now,
                                               observedSince: observedSince)
        // Incidents open now stay open across a later observation gap until evidence clears them (M9 R2).
        if observe {
            observation.noteOpen(Set(projects.flatMap(\.attentionItems).compactMap { item in
                switch item.kind {
                case .stalledThread: item.threadId
                case .silentSubagent: item.subagentId
                case .waitingForOwner: nil
                }
            }))
        }
        var result = Snapshot(projects: projects, statuses: statuses, checkedAt: now, indexing: indexing)
        result.t3Outage = observe ? t3Outage : nil
        return result
    }

    /// A full pass, then catch-up passes (no folder walk) until every collector is caught up.
    /// `progress` receives a snapshot at most every `progressInterval` seconds and at the end.
    public func indexToCompletion(progressInterval: TimeInterval = 2, progress: @Sendable (Snapshot) async -> Void = { _ in }) async -> Snapshot {
        var snapshot = await pass(now: Date())
        await progress(snapshot)
        var lastReport = Date()
        while snapshot.indexing {
            let report = Date().timeIntervalSince(lastReport) >= progressInterval
            let before = bytesReadTotal
            snapshot = await pass(now: Date(), scope: .pending, resolve: report)
            // Safety stop: a pass that reads nothing cannot make progress.
            if bytesReadTotal == before { break }
            if report {
                await progress(snapshot)
                lastReport = Date()
            }
        }
        snapshot = await pass(now: Date())
        await progress(snapshot)
        return snapshot
    }
}
