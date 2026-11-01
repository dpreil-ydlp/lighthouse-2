import Foundation

/// Attention kinds (SPEC §5.4).
public enum AttentionKind: String, Sendable, Hashable, Codable {
    case waitingForOwner
    case silentSubagent
    case stalledThread

    /// The attention-strip bucket (SPEC §6.2 item 3): "Needs you" or "Gone quiet".
    public var bucket: AttentionBucket { self == .waitingForOwner ? .needsYou : .goneQuiet }
}

public enum AttentionBucket: String, Sendable, Hashable, CaseIterable {
    case needsYou
    case goneQuiet

    public var title: String {
        switch self {
        case .needsYou: "Needs you"
        case .goneQuiet: "Gone quiet"
        }
    }
}

/// One open attention incident. `id` is the incident identity (SPEC §5.4): (subject, kind,
/// condition-entered-at), with the T3 request id in place of the entry time for waiting items.
public struct AttentionItem: Sendable, Hashable, Identifiable, Codable {
    public var id: String
    public var kind: AttentionKind
    public var threadId: String
    public var subagentId: String?
    public var enteredAt: Date
    /// Request kind or silence only; never request or message text.
    public var label: String
}

/// When Lighthouse has watched a subject without a gap. A stall or silence needs 30 min of
/// observed silence, so time the Mac slept, or a source was unreadable, never counts (SPEC §5.4,
/// §11 M4 sleep/wake and recovery fixtures). The incident identity still comes from the evidence
/// time alone, so it is the same before and after a restart or a gap.
public typealias ObservedSince = @Sendable (String) -> Date

public enum AttentionRules {
    /// A running subagent with no activity, or a running thread with no progress evidence, for this
    /// long is silent or stalled (SPEC §5.4).
    public static let silenceAfter: TimeInterval = 30 * 60
    public static let alwaysObserved: ObservedSince = { _ in .distantPast }
    /// A tool call T3 shows in flight exempts its thread or subagent from stall and silence for at
    /// most this long (M9 F1, the busy gate). A longer call no longer exempts; the stall then needs
    /// 30 more minutes of observed time, because the end of a busy spell restarts observation.
    public static let busyCap: TimeInterval = 2 * 3600

    /// True while a tool call has been in flight for less than `busyCap` (M9 F1).
    public static func isBusy(_ since: Date?, now: Date) -> Bool {
        guard let since else { return false }
        return now.timeIntervalSince(since) < busyCap
    }

    /// Open items for one thread, before acknowledgements are applied.
    public static func items(for thread: SessionThread, now: Date, observedSince: ObservedSince = alwaysObserved) -> [AttentionItem] {
        var items: [AttentionItem] = []
        if thread.state == .waitingForOwner, let request = thread.pendingRequest {
            items.append(AttentionItem(id: "\(AttentionKind.waitingForOwner.rawValue)|\(thread.id)|\(request.id)", kind: .waitingForOwner,
                                       threadId: thread.id, enteredAt: request.createdAt ?? thread.lastActivityAt,
                                       label: "\(request.label) · \(thread.displayTitle)"))
        }
        for sub in thread.subagents where sub.state == .waitingForOwner {
            guard let request = sub.pendingRequest else { continue }
            items.append(AttentionItem(id: "\(AttentionKind.waitingForOwner.rawValue)|\(sub.id)|\(request.id)", kind: .waitingForOwner,
                                       threadId: thread.id, subagentId: sub.id, enteredAt: request.createdAt ?? sub.lastActivityAt,
                                       label: "\(request.label) · \(sub.name)"))
        }
        if let reference = stallReference(of: thread, now: now, observedSince: observedSince) {
            let entered = reference.addingTimeInterval(silenceAfter)
            items.append(AttentionItem(id: "\(AttentionKind.stalledThread.rawValue)|\(thread.id)|\(Int(entered.timeIntervalSince1970))",
                                       kind: .stalledThread, threadId: thread.id, enteredAt: entered,
                                       label: "No progress · \(thread.displayTitle)"))
        }
        for sub in silentSubagents(of: thread, now: now, observedSince: observedSince) {
            let entered = sub.lastActivityAt.addingTimeInterval(silenceAfter)
            items.append(AttentionItem(id: "\(AttentionKind.silentSubagent.rawValue)|\(sub.id)|\(Int(entered.timeIntervalSince1970))",
                                       kind: .silentSubagent, threadId: thread.id, subagentId: sub.id, enteredAt: entered,
                                       label: "Subagent silent · \(sub.name)"))
        }
        return items
    }

    /// Running subagents with a fresh source read and no activity for 30 min of observed time, not
    /// waiting. Never for Claude Code-owned threads (SPEC §5.3: stall and silence detection
    /// unavailable there). A new activity moves `lastActivityAt`, so a later silence has a new entry
    /// time: a new incident.
    public static func silentSubagents(of thread: SessionThread, now: Date, observedSince: ObservedSince = alwaysObserved) -> [Subagent] {
        guard thread.owningApp != .claudeCode else { return [] }
        return thread.subagents.filter { sub in
            sub.state == .running
                && !isBusy(sub.busySince, now: now)
                && now.timeIntervalSince(sub.sourceReadAt) <= StateRules.sourceStaleAfter
                && now.timeIntervalSince(max(sub.lastActivityAt, observedSince(sub.id))) >= silenceAfter
        }
    }

    /// The newest progress evidence of a running turn: the latest of the last progress, the turn
    /// start, and its subagents' progress (a child's real progress and completion are the parent's
    /// progress; its activity alone is not, SPEC §5.3, M4-R06). Nil when progress cannot be
    /// observed (Claude Code-owned, unknown run start, no fresh provider session): no stall is
    /// raised then (SPEC §5.4 "Coverage unknown").
    public static func progressReference(of thread: SessionThread) -> Date? {
        guard thread.owningApp != .claudeCode, thread.progressCoverage, let started = thread.runningSince else { return nil }
        let children = thread.subagents.compactMap(\.lastProgressAt)
        return ([started, thread.lastProgressAt ?? started] + children).max()!
    }

    /// A parent is waiting on a subagent, not stalled, while one is waiting for the owner, is
    /// still making progress (within 30 min of observed time), or is itself silent (its own item
    /// covers it). A running child that only shows activity without progress for 30 min no longer
    /// exempts the parent (M4-R06).
    static func waitingOnSubagent(_ thread: SessionThread, now: Date, observedSince: ObservedSince) -> Bool {
        let silent = Set(silentSubagents(of: thread, now: now, observedSince: observedSince).map(\.id))
        return thread.subagents.contains { sub in
            if sub.state == .waitingForOwner { return true }
            guard sub.state == .running else { return false }
            if silent.contains(sub.id) || isBusy(sub.busySince, now: now) { return true }
            let reference = sub.lastProgressAt ?? sub.startedAt ?? sub.lastActivityAt
            return now.timeIntervalSince(max(reference, observedSince(sub.id))) < silenceAfter
        }
    }

    /// SPEC §5.4 `stalledThread`: running (not waiting) with a fresh source read and no progress
    /// evidence for 30 min of observed time. Returns the progress reference the incident is keyed on.
    /// A parent waiting on a progressing, waiting or silent subagent is not stalled (`waitingOnSubagent`).
    public static func stallReference(of thread: SessionThread, now: Date, observedSince: ObservedSince = alwaysObserved) -> Date? {
        guard thread.state == .running, !isBusy(thread.busySince, now: now),
              now.timeIntervalSince(thread.sourceReadAt) <= StateRules.sourceStaleAfter,
              !waitingOnSubagent(thread, now: now, observedSince: observedSince),
              let reference = progressReference(of: thread) else { return nil }
        return now.timeIntervalSince(max(reference, observedSince(thread.id))) >= silenceAfter ? reference : nil
    }

    /// What the thread detail shows for stall detection, or nil when nothing needs saying.
    public static func stallNote(for thread: SessionThread) -> String? {
        if thread.owningApp == .claudeCode { return "Stall detection unavailable for Claude Code" }
        if thread.state == .running && progressReference(of: thread) == nil { return "Coverage unknown" }
        return nil
    }

    /// Project-row reasons: waiting items first, then one line each for stalled threads
    /// (`1 thread stalled · 31 m`) and silent subagents (`1 subagent silent · 31 m`).
    public static func reasons(_ items: [AttentionItem], now: Date) -> [String] {
        var reasons = items.filter { $0.kind == .waitingForOwner }.sorted { $0.enteredAt < $1.enteredAt }.map(\.label)
        for (kind, noun, verb) in [(AttentionKind.stalledThread, "thread", "stalled"), (.silentSubagent, "subagent", "silent")] {
            let matching = items.filter { $0.kind == kind }
            guard let oldest = matching.map(\.enteredAt).min() else { continue }
            let since = oldest.addingTimeInterval(-silenceAfter)
            reasons.append("\(matching.count) \(noun)\(matching.count == 1 ? "" : "s") \(verb) · \(shortAge(now.timeIntervalSince(since)))")
        }
        return reasons
    }

    /// Counts for the attention strip (`◆ Needs you 2 · Gone quiet 1`).
    public static func counts(_ projects: [ProjectSummary]) -> [AttentionBucket: Int] {
        var result: [AttentionBucket: Int] = [:]
        for item in projects.flatMap(\.attentionItems) { result[item.kind.bucket, default: 0] += 1 }
        return result
    }

    static func shortAge(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        if minutes < 60 { return "\(minutes) m" }
        if minutes < 48 * 60 { return "\(minutes / 60) h" }
        return "\(minutes / 1440) d"
    }
}

/// Tracks, per subject, since when it has been observed without a gap (`ObservedSince`).
///
/// - A gap between passes longer than the stale bound (the Mac slept, the app hung) restarts every
///   subject's observation at the next pass.
/// - A subject that was `unknown` at the previous resolution (its source was unreadable or stale)
///   restarts when it becomes known again (recovery). A busy subject (a tool call in flight, M9 F1)
///   counts as unknown here, so the end of a busy spell restarts it too.
/// - A subject first seen after the first resolution (a new session, or one indexed late) starts
///   when seen. Subjects seen at the first resolution of a run count as observed, so a restart
///   raises an incident that was open before it again, with the same identity.
public struct ObservationTracker: Sendable {
    private var lastPassAt: Date?
    private var resetAt = Date.distantPast
    private var startedAt: [String: Date] = [:]
    private var unknown = Set<String>()
    private var resolved = false
    /// Subjects with an open stall or silence at the last resolution (M9 R2).
    private var open = Set<String>()

    /// Records the subjects whose stall or silence is open after a resolution. A gap (sleep, a hang)
    /// does not hide them: their incident stays open, with the same identity, until new evidence
    /// clears it or the subject turns unknown. Before M9 an open incident vanished for 30 min after
    /// every gap and came back under the same identity.
    public mutating func noteOpen(_ subjects: Set<String>) { open = subjects }

    public init() {}

    public mutating func notePass(at now: Date) {
        if let lastPassAt, now.timeIntervalSince(lastPassAt) > StateRules.sourceStaleAfter { resetAt = now }
        lastPassAt = now
    }

    /// Records the subjects of one resolution and returns their observation starts.
    public mutating func observe(_ threads: [SessionThread], now: Date) -> ObservedSince {
        var present: [String: ThreadState] = [:]
        for thread in threads {
            // Lost progress coverage (a mapped provider session gone stale) is unobserved time too (M4-R05).
            // So is a busy spell (M9 F1): when a tool call ends, the silence clock starts then, so
            // the reply that follows the tool has time to arrive before a stall can be raised.
            let threadBusy = AttentionRules.isBusy(thread.busySince, now: now)
            present[thread.id] = thread.progressCoverage && !threadBusy ? thread.state : .unknown
            for sub in thread.subagents { present[sub.id] = AttentionRules.isBusy(sub.busySince, now: now) ? .unknown : sub.state }
        }
        var next: [String: Date] = [:]
        var nextUnknown = Set<String>()
        for (id, state) in present {
            if state == .unknown { nextUnknown.insert(id) }
            if let start = startedAt[id], !(unknown.contains(id) && state != .unknown) {
                next[id] = start
            } else {
                next[id] = resolved ? now : .distantPast
            }
        }
        startedAt = next
        unknown = nextUnknown
        resolved = true
        let starts = next, reset = resetAt
        // Subjects that turned unknown lose their open status (recovery restarts their clock).
        let kept = open.subtracting(nextUnknown)
        open = kept
        return { id in kept.contains(id) ? (starts[id] ?? now) : max(starts[id] ?? now, reset) }
    }
}
