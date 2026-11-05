import Foundation

/// Nudges (SPEC 2.11, owner request 2026-11-03): with the switch on, a stalled T3 Code parent thread
/// gets a fixed "please continue" message through T3's own MCP server (`T3Link`), at most `limit`
/// times. When that has not helped, the thread counts as Needs you. Subagents, Claude Code threads
/// and Codex app threads are never nudged: only T3 can take a message for a given thread.
///
/// The count belongs to an episode, not a run: a nudge can make T3 start a new run, and a count
/// that reset with every run would nudge a thread that keeps hanging forever. An episode starts with
/// its first nudge and ends after `episode` (24 h), or once the thread has been seen not running for
/// `restAfter` (its turn finished, or the owner took over).
public enum NudgePolicy {
    /// Nudges per episode before the thread is handed to the owner (owner: "a limit of 3").
    public static let limit = 3
    /// Time between nudges while the stall stays open, and after the last one before Needs you.
    public static let spacing: TimeInterval = 15 * 60
    /// A failed send is tried again after this long; it does not count toward the limit.
    public static let retryAfter: TimeInterval = 15 * 60
    /// Longest an episode lasts, counted from its first nudge.
    public static let episode: TimeInterval = 24 * 3600
    /// Not running this long ends the episode.
    public static let restAfter: TimeInterval = 10 * 60

    /// The T3 thread to send to: a running T3-owned parent thread with a plain T3 thread id.
    public static func target(_ thread: SessionThread) -> String? {
        guard thread.owningApp == .t3, (thread.state == .running || thread.continueWorkAt != nil && thread.state == .idle), let id = thread.t3ThreadId, T3Link.validThreadId(id) else { return nil }
        return id
    }

    /// Idle work requires current model evidence, fresh source data, and no owner or child dependency.
    public static func idleWork(_ thread: SessionThread, now: Date) -> Bool {
        guard thread.state == .idle, thread.owningApp == .t3,
              thread.continueWorkAt == thread.lastActivityAt,
              thread.pendingRequest == nil, thread.asksOwnerAt == nil, thread.settledAt == nil,
              thread.busySince == nil, thread.subagents.allSatisfy({ $0.state != .running && $0.state != .waitingForOwner }),
              now.timeIntervalSince(thread.sourceReadAt) <= StateRules.sourceStaleAfter,
              now.timeIntervalSince(thread.lastActivityAt) >= AttentionRules.silenceAfter,
              now.timeIntervalSince(thread.lastActivityAt) < ReplyDetector.window else { return false }
        return true
    }

    /// The record when its episode is still open at `now`, else nil.
    public static func current(_ record: NudgeRecord?, now: Date) -> NudgeRecord? {
        guard let record, now.timeIntervalSince(record.episodeStart) < episode else { return nil }
        return record
    }

    /// As `current`, and settling the thread in T3 ends the episode (SPEC 2.14): an episode that
    /// began at or before `settledAt` is over, so it sends no further nudge and marks nothing.
    public static func current(_ record: NudgeRecord?, settledAt: Date?, now: Date) -> NudgeRecord? {
        guard let record = current(record, now: now) else { return nil }
        if let settledAt, record.episodeStart <= settledAt { return nil }
        return record
    }

    /// True when a nudge should go out now: the stall is open, the episode has had fewer than `limit`
    /// nudges, and the last nudge (or failed try) is at least `spacing` old.
    public static func isDue(_ thread: SessionThread, stallOpen: Bool, record: NudgeRecord?, now: Date) -> Bool {
        guard stallOpen, target(thread) != nil else { return false }
        guard let record = current(record, now: now) else { return true }
        guard record.count < limit else { return false }
        if let sent = record.lastSentAt, now.timeIntervalSince(sent) < spacing { return false }
        if let failed = record.lastFailedAt, now.timeIntervalSince(failed) < retryAfter { return false }
        return true
    }

    /// When the thread was handed to the owner: `limit` nudges went out in this episode, the stall is
    /// open, and `spacing` has passed since the last one. Nil otherwise.
    public static func exhaustedAt(stallOpen: Bool, mark: NudgeMark?, now: Date) -> Date? {
        guard stallOpen, let mark, mark.count >= limit, let sent = mark.lastSentAt else { return nil }
        let at = sent.addingTimeInterval(spacing)
        return now >= at ? at : nil
    }

    /// The fixed text sent into the thread. No model writes it and it carries no thread content.
    public static func message(number: Int) -> String {
        "Lighthouse (nudge \(number) of \(limit)): this thread has shown no progress for 30 minutes. "
            + "Please continue the task. If you are blocked or need something from me, say what you need."
    }

    /// T3's `clientRequestId` for one nudge: the same nudge sent twice is one message in T3.
    public static func requestId(threadId: String, episodeKey: String, number: Int) -> String {
        "lighthouse-nudge-\(threadId)-\(episodeKey)-\(number)"
    }

    /// Ends episodes that are over: 24 h old, the thread gone, or the thread not running for
    /// `restAfter`. Notes when a thread stops running and clears that when it runs again.
    /// Returns the records to keep; `changed` and `removed` say what to write to the store.
    public static func reconcile(_ records: [String: NudgeRecord], threads: [SessionThread], now: Date)
        -> (records: [String: NudgeRecord], changed: [NudgeRecord], removed: [String]) {
        let byId = Dictionary(threads.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var kept: [String: NudgeRecord] = [:], changed: [NudgeRecord] = [], removed: [String] = []
        for (id, record) in records {
            guard let thread = byId[id], current(record, settledAt: thread.settledAt, now: now) != nil else { removed.append(id); continue }
            var next = record
            // A completed turn invalidates its prior judgment. Preserve the counter while
            // its replacement is unavailable; only current positive evidence permits a send.
            let judgmentPending = thread.state == .idle && thread.continueWorkJudgedAt != thread.lastActivityAt
            if thread.state == .running || judgmentPending || (thread.continueWorkAt != nil && thread.continueWorkAt == thread.lastActivityAt) {
                next.restingSince = nil
            } else if let resting = record.restingSince {
                if now.timeIntervalSince(resting) >= restAfter { removed.append(id); continue }
            } else {
                next.restingSince = now
            }
            kept[id] = next
            if next != record { changed.append(next) }
        }
        return (kept, changed, removed)
    }
}

/// Nudges sent to one thread in one episode. Stored in `nudges` (thread id, counts and times only).
public struct NudgeRecord: Sendable, Hashable {
    public var threadId: String
    /// Time of the episode's first nudge (or first try).
    public var episodeStart: Date
    public var count: Int
    public var lastSentAt: Date?
    public var lastFailedAt: Date?
    /// When the thread was first seen not running in this episode; nil while it runs.
    public var restingSince: Date?

    public init(threadId: String, episodeStart: Date, count: Int = 0, lastSentAt: Date? = nil, lastFailedAt: Date? = nil, restingSince: Date? = nil) {
        self.threadId = threadId
        self.episodeStart = episodeStart
        self.count = count
        self.lastSentAt = lastSentAt
        self.lastFailedAt = lastFailedAt
        self.restingSince = restingSince
    }

    public var episodeKey: String { String(Int(episodeStart.timeIntervalSince1970)) }
}

/// What the shelf shows for a thread's nudges in its current episode (set by the engine).
public struct NudgeMark: Sendable, Hashable, Codable {
    public var count: Int
    public var lastSentAt: Date?
    public var episodeKey: String

    public init(count: Int, lastSentAt: Date?, episodeKey: String) {
        self.count = count
        self.lastSentAt = lastSentAt
        self.episodeKey = episodeKey
    }
}

/// One nudge to send now.
public struct NudgeCandidate: Sendable, Hashable {
    public var threadId: String
    public var t3ThreadId: String
    public var episodeStart: Date
    /// 1, 2 or 3.
    public var number: Int
    public var title: String

    public var episodeKey: String { String(Int(episodeStart.timeIntervalSince1970)) }
}

extension NudgePolicy {
    /// The next nudge due across the shelf: the longest-stalled eligible thread first. Only threads
    /// with an open `stalledThread` item count, so a thread that is waiting, busy, quiet without a
    /// proven running state, or a subagent is never chosen.
    public static func next(_ projects: [ProjectSummary], records: [String: NudgeRecord], now: Date) -> NudgeCandidate? {
        var best: (candidate: NudgeCandidate, since: Date)?
        for project in projects {
            let stalled = Dictionary(project.attentionItems.filter { $0.kind == .stalledThread && $0.subagentId == nil }.map { ($0.threadId, $0.enteredAt) },
                                     uniquingKeysWith: min)
            for thread in project.threads {
                // An episode from before a settle is over (SPEC 2.14); a later stall starts a new one.
                let open = current(records[thread.id], settledAt: thread.settledAt, now: now)
                guard let since = stalled[thread.id], let target = target(thread),
                      isDue(thread, stallOpen: true, record: open, now: now) else { continue }
                let candidate = NudgeCandidate(threadId: thread.id, t3ThreadId: target, episodeStart: open?.episodeStart ?? now,
                                               number: (open?.count ?? 0) + 1, title: thread.displayTitle)
                if best == nil || since < best!.since { best = (candidate, since) }
            }
        }
        return best?.candidate
    }

    /// The record to save before sending: the nudge counts from the moment it is attempted, so a
    /// crash mid-send never sends it twice (T3 also drops a repeat with the same request id).
    public static func attempted(_ candidate: NudgeCandidate, at now: Date) -> NudgeRecord {
        NudgeRecord(threadId: candidate.threadId, episodeStart: candidate.episodeStart, count: candidate.number, lastSentAt: now)
    }

    /// The record after a failed send: the attempt does not count, and the next try waits `retryAfter`.
    public static func failed(_ candidate: NudgeCandidate, previous: NudgeRecord?, at now: Date) -> NudgeRecord {
        let kept = current(previous, now: now)
        return NudgeRecord(threadId: candidate.threadId, episodeStart: candidate.episodeStart, count: candidate.number - 1,
                           lastSentAt: kept?.lastSentAt, lastFailedAt: now)
    }
}
