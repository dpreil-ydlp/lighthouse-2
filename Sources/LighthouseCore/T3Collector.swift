import Foundation

/// Result of one T3 pass: the last successfully read state (kept across skipped passes so its
/// threads turn `unknown` once the read is stale, SPEC §5.3) and the collector status line.
public struct T3PassResult: Sendable {
    public var state: T3State?
    /// Time of the last successful read.
    public var readAt: Date?
    public var status: CollectorStatus
    /// True when this pass read new data or changed the error line.
    public var changed: Bool
    /// Duration of the read attempt in seconds (nil when the pass was throttled).
    public var seconds: Double?
    /// Increases whenever `state` changes (full or targeted read). The engine applies a result only
    /// when it is newer than the one it holds, so an earlier result can never replace a later one.
    public var version: Int = 0
}

/// Polls the T3 reader (SPEC §4). T3 writes its database constantly, so it is not watched with
/// FSEvents; a pass reads at most once per `minInterval`, and not at all when the database and WAL
/// are unchanged since the last good read and the sidecar preflight still passes (no SQL). Nothing is persisted: T3 metadata lives in
/// memory only, and a failed read keeps the previous state without any fallback read path.
///
/// Cadence: a read of a large T3 database costs noticeable CPU, so reading at most every 60 s keeps
/// T3 polling small while T3 is busy (SPEC §3.2 idle < 1 %). It matches the JSONL rescan; waiting and silence (≥ 30 min) are seen within a minute.
public actor T3Collector {
    public static let defaultMinInterval: TimeInterval = 60

    public nonisolated let reader: T3Reader
    public let minInterval: TimeInterval
    private var state: T3State?
    private var readAt: Date?
    private var lastAttempt: Date?
    private var error: String?
    private var readStamps: [FileStat?]?
    public private(set) var lastSeconds: Double?
    /// Counters for the live log: passes that were due, of which SQLite reads and stat-confirmed skips.
    public private(set) var attempts = 0
    public private(set) var reads = 0
    public private(set) var unchangedSkips = 0
    /// Targeted reads (SPEC 2.13): SQL reads, and those that changed the state.
    public private(set) var subjectReads = 0
    public private(set) var subjectChanges = 0
    private var version = 0
    /// File stamps the last targeted check saw, and failed targeted reads at those stamps.
    private var subjectStamps: [FileStat?]?
    private var subjectFailures = 0
    /// Index of each thread id in `state.threads`, built on the first targeted read after a full read.
    private var positions: [String: Int]?
    /// A targeted read that fails is retried at the same stamps at most this often; the next
    /// commit, or the full read, then takes over (bounded retry).
    static let subjectRetries = 3
    /// At most one targeted read per this many seconds, however often T3 commits (CPU bound; the
    /// app checks every 250 ms, so a resolution shows within about 0.5 s of T3's commit).
    public static let defaultSubjectSpacing: TimeInterval = 0.5
    public let subjectSpacing: TimeInterval
    private var lastSubjectRead: TimeInterval?
    public var lastError: String? { error }

    public init(reader: T3Reader = T3Reader(), minInterval: TimeInterval = T3Collector.defaultMinInterval,
                subjectSpacing: TimeInterval = T3Collector.defaultSubjectSpacing) {
        self.reader = reader
        self.minInterval = minInterval
        self.subjectSpacing = subjectSpacing
    }

    public func pass(now: Date, force: Bool = false) -> T3PassResult {
        if !force, let lastAttempt, now.timeIntervalSince(lastAttempt) < minInterval {
            return T3PassResult(state: state, readAt: readAt, status: status(now: lastAttempt), changed: false, seconds: nil, version: version)
        }
        lastAttempt = now
        attempts += 1
        if state != nil, error == nil, let readStamps, readStamps == reader.fileStamps() {
            // Unchanged database and WAL. Freshness is renewed only if the sidecar pair still passes
            // the same fail-closed preflight as a read (M3-R01: a removed or truncated `-shm`).
            if let failure = reader.preflight() {
                error = failure.description
                return T3PassResult(state: state, readAt: readAt, status: status(now: now), changed: true, seconds: 0, version: version)
            }
            readAt = now   // Confirmed unchanged without opening the database.
            unchangedSkips += 1
            return T3PassResult(state: state, readAt: readAt, status: status(now: now), changed: false, seconds: 0, version: version)
        }
        let stamps = reader.fileStamps()
        let started = DispatchTime.now().uptimeNanoseconds
        let result = reader.read()
        reads += 1
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
        lastSeconds = seconds
        var changed: Bool
        switch result {
        case .success(let fresh):
            changed = fresh != state || error != nil
            if fresh != state { version += 1; positions = nil }
            state = fresh
            readAt = now
            error = nil
            readStamps = stamps
            subjectStamps = stamps   // This read already holds every counted thread at these stamps.
            subjectFailures = 0
        case .failure(let failure):
            let message = failure.description
            changed = message != error
            error = message
        }
        return T3PassResult(state: state, readAt: readAt, status: status(now: now), changed: changed, seconds: seconds, version: version)
    }

    /// Targeted refresh of the threads behind open Needs-you items (SPEC 2.13). Costs two `stat`
    /// calls when T3 committed nothing since the last check; otherwise reads only those threads.
    /// Returns the patched state and its version when it changed, nil otherwise.
    ///
    /// - It never renews `readAt`: a partial read does not make the rest of the state fresh.
    /// - It runs only on top of a good full read (`state` set, no read error); a failed full read
    ///   keeps the last state as it is.
    /// - A failed targeted read changes nothing, so open items stay open (fail closed).
    public func refreshSubjects(_ ids: Set<String>) -> (state: T3State, version: Int)? {
        guard !ids.isEmpty, var patched = state, error == nil else { return nil }
        let stamps = reader.fileStamps()
        if stamps == subjectStamps { return nil }
        let tick = reader.clock()
        if let last = lastSubjectRead, tick - last < subjectSpacing { return nil }
        lastSubjectRead = tick
        subjectReads += 1
        switch reader.readSubjects(ids.sorted()) {
        case .failure:
            subjectFailures += 1
            if subjectFailures >= Self.subjectRetries { subjectStamps = stamps; subjectFailures = 0 }
            return nil
        case .success(let subjects):
            subjectStamps = stamps
            subjectFailures = 0
            let lookup = positions ?? Self.positions(of: patched)
            positions = lookup
            guard Self.apply(subjects, to: &patched, positions: lookup) else { return nil }
            state = patched
            positions = nil
            version += 1
            subjectChanges += 1
            return (patched, version)
        }
    }

    static func positions(of state: T3State) -> [String: Int] {
        Dictionary(state.threads.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Writes targeted rows into `state`, as a full read at the same moment would show them.
    /// Returns whether anything changed.
    static func apply(_ subjects: [String: T3Reader.Subject], to state: inout T3State, positions: [String: Int]? = nil) -> Bool {
        let positions = positions ?? Self.positions(of: state)
        var changed = false
        var removed = Set<String>()
        // Pending requests of the subjects only; the list holds every pending row T3 has (few).
        let current = Dictionary(grouping: state.pendingRequests.filter { subjects[$0.threadId] != nil }, by: \.threadId)
        var replaced = Set<String>()
        for (id, subject) in subjects {
            let position = positions[id]
            guard let archived = subject.archived else {
                // Deleted or gone: a full read would not list the thread, its run or its requests.
                if position != nil { removed.insert(id) }
                if state.runs[id] != nil { state.runs.removeValue(forKey: id); changed = true }
                if current[id] != nil { replaced.insert(id) }
                continue
            }
            if let position, state.threads[position].archived != archived {
                state.threads[position].archived = archived
                changed = true
            }
            if state.runs[id] != subject.run {
                state.runs[id] = subject.run
                changed = true
            }
            if Set(current[id] ?? []) != Set(subject.pending) { replaced.insert(id) }
        }
        if !removed.isEmpty {
            state.threads.removeAll { removed.contains($0.id) }
            changed = true
        }
        if !replaced.isEmpty {
            state.pendingRequests.removeAll { replaced.contains($0.threadId) }
            for id in replaced.sorted() { state.pendingRequests += subjects[id]?.pending ?? [] }
            changed = true
        }
        return changed
    }

    private func status(now: Date) -> CollectorStatus {
        let parents = state.map { s in s.threads.filter { $0.lineageParent == nil }.count } ?? 0
        return CollectorStatus(source: .t3, lastReadAt: readAt ?? now, threadCount: parents, filesIndexed: state == nil ? 0 : 1,
                               filesInWindow: state == nil ? 0 : 1, filesNotIndexed: 0, skippedLines: 0, error: error)
    }
}
