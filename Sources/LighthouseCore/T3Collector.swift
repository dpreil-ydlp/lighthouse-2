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
    public var lastError: String? { error }

    public init(reader: T3Reader = T3Reader(), minInterval: TimeInterval = T3Collector.defaultMinInterval) {
        self.reader = reader
        self.minInterval = minInterval
    }

    public func pass(now: Date, force: Bool = false) -> T3PassResult {
        if !force, let lastAttempt, now.timeIntervalSince(lastAttempt) < minInterval {
            return T3PassResult(state: state, readAt: readAt, status: status(now: lastAttempt), changed: false, seconds: nil)
        }
        lastAttempt = now
        attempts += 1
        if state != nil, error == nil, let readStamps, readStamps == reader.fileStamps() {
            // Unchanged database and WAL. Freshness is renewed only if the sidecar pair still passes
            // the same fail-closed preflight as a read (M3-R01: a removed or truncated `-shm`).
            if let failure = reader.preflight() {
                error = failure.description
                return T3PassResult(state: state, readAt: readAt, status: status(now: now), changed: true, seconds: 0)
            }
            readAt = now   // Confirmed unchanged without opening the database.
            unchangedSkips += 1
            return T3PassResult(state: state, readAt: readAt, status: status(now: now), changed: false, seconds: 0)
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
            state = fresh
            readAt = now
            error = nil
            readStamps = stamps
        case .failure(let failure):
            let message = failure.description
            changed = message != error
            error = message
        }
        return T3PassResult(state: state, readAt: readAt, status: status(now: now), changed: changed, seconds: seconds)
    }

    private func status(now: Date) -> CollectorStatus {
        let parents = state.map { s in s.threads.filter { $0.lineageParent == nil }.count } ?? 0
        return CollectorStatus(source: .t3, lastReadAt: readAt ?? now, threadCount: parents, filesIndexed: state == nil ? 0 : 1,
                               filesInWindow: state == nil ? 0 : 1, filesNotIndexed: 0, skippedLines: 0, error: error)
    }
}
