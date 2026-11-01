import Foundation

/// Observed-state rules (SPEC §5.3). State comes from log records only; Lighthouse never asks an agent.
/// Age alone never ends a thread: JSONL sources record no "closed" event, so they never produce
/// `stopped`. Old inactive threads are folded for display only (SPEC 2.4 §6.4, `ThreadDisplay`).
public enum StateRules {
    /// Claude: an unanswered user or tool-result record counts as running only within this window.
    public static let claudeRunningWindow: TimeInterval = 10 * 60
    /// A source not successfully read for this long makes its threads unknown (SPEC §5.3 "stale > 5 min").
    public static let sourceStaleAfter: TimeInterval = 5 * 60

    /// SPEC 2.2 §5.3: running only when the last user/assistant record is a user or tool-result record
    /// under 10 min old; idle only when the last assistant record has `stop_reason = end_turn`;
    /// anything else is unknown.
    public static func claude(lastTurnKind: ClaudeTurnKind?, lastTurnRecordAt: Date?, sourceReadAt: Date, now: Date) -> ThreadState {
        if now.timeIntervalSince(sourceReadAt) > sourceStaleAfter { return .unknown }
        switch lastTurnKind {
        case .userOrToolResult?:
            guard let at = lastTurnRecordAt else { return .unknown }
            return now.timeIntervalSince(at) < claudeRunningWindow ? .running : .unknown
        case .assistantEndTurn?:
            return .idle
        case .assistantOther?, nil:
            return .unknown
        }
    }

    /// Codex: `task_started` without a later `task_complete` is running, however old; after
    /// `task_complete` idle; anything else (no task events, `turn_aborted`) is unknown.
    public static func codex(turnOpen: Bool?, sourceReadAt: Date, now: Date) -> ThreadState {
        if now.timeIntervalSince(sourceReadAt) > sourceStaleAfter { return .unknown }
        switch turnOpen {
        case true?: return .running
        case false?: return .idle
        case nil: return .unknown
        }
    }

    /// T3 run statuses that mean a turn is in progress.
    public static let t3ActiveRuns: Set<String> = ["queued", "preparing", "starting", "running", "waiting"]
    /// Pending runtime-request kinds that wait for the owner: approvals (command, file change, file
    /// read) and user input. Other kinds raise nothing.
    public static let t3WaitingKinds: Set<String> = ["approval", "command", "file-change", "file-read", "user_input", "user-input"]

    /// T3 thread (SPEC §5.3): running while its newest run is active; waiting when it also has a
    /// pending approval or user-input request; idle after the run ends; stopped when archived and
    /// not running. A pending request on a thread whose newest run has ended is a leftover, not a
    /// wait (T3 can leave such rows behind), so it raises nothing.
    public static func t3Thread(runStatus: String?, pending: PendingRequest?, archived: Bool, sourceReadAt: Date, now: Date) -> ThreadState {
        if now.timeIntervalSince(sourceReadAt) > sourceStaleAfter { return .unknown }
        if let runStatus, t3ActiveRuns.contains(runStatus) {
            return pending != nil ? .waitingForOwner : .running
        }
        return archived ? .stopped : .idle
    }

    /// T3 delegated-task row: `running` (waiting when the child thread has a live pending request),
    /// `completed` idle, `failed`/`cancelled`/`interrupted` stopped, anything else unknown.
    public static func t3Subagent(status: String, childWaiting: Bool, sourceReadAt: Date, now: Date) -> ThreadState {
        if now.timeIntervalSince(sourceReadAt) > sourceStaleAfter { return .unknown }
        switch status {
        case "running", "queued", "starting": return childWaiting ? .waitingForOwner : .running
        case "completed": return .idle
        case "failed", "cancelled", "interrupted": return .stopped
        default: return .unknown
        }
    }
}
