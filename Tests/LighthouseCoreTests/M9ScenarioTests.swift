import Foundation
import Testing
@testable import LighthouseCore

/// Checkpoint store that drops every save, like a process killed before its pass committed.
final class CrashingCheckpoints: CheckpointStore, @unchecked Sendable {
    let inner: Store
    init(_ inner: Store) { self.inner = inner }
    func loadCheckpoints(source: SourceKind) -> [String: StoredCheckpoint] { inner.loadCheckpoints(source: source) }
    func saveCheckpoints(source: SourceKind, changed: [StoredCheckpoint], removed: [String]) {}
}

/// M9 owner failure scenarios (§5 of the owner request) that existing v2 mechanisms already cover.
/// They pass at `fadab14` and on the candidate; the scenario table in docs/reliability/SCENARIOS.md
/// maps each one. Mock-level only: test data, fake senders, no real crash, no real T3.
extension M4Tests {
    /// Scenario 1: Lighthouse dies in the middle of a pass. Each pass commits its checkpoints (offset
    /// and derived state together) in one transaction, so the next run reads from the last commit
    /// and counts nothing twice.
    @Test func m9ScenarioDeathMidPassCountsNothingTwice() async throws {
        let s = Scratch()
        let cwd = runningCodex(s, id: "c-mid")
        let url = s.url.appendingPathComponent("app/lighthouse.sqlite")
        let st = try Store(url: url)
        _ = await CodexCollector(codexHome: s.codexHome, store: st).pass(now: at("09:10:00"))
        s.append(Self.rollout("c-mid"), Self.tokens(250, "09:12:00"))
        // This run reads the new line, then dies before its checkpoint commit.
        let dying = await CodexCollector(codexHome: s.codexHome, store: CrashingCheckpoints(st)).pass(now: at("09:13:00"))
        #expect(dying.threads.first?.tokensTotal == 250)
        // The next run resumes from the committed checkpoint: the line is read once more, counted once.
        let next = CodexCollector(codexHome: s.codexHome, store: try Store(url: url))
        let result = await next.pass(now: at("09:14:00"))
        #expect(result.threads.first?.tokensTotal == 250)
        #expect(result.bytesRead > 0)
        #expect(result.threads.first?.cwd == cwd)
    }

    /// Scenario 3: the same event arrives twice (a duplicate FSEvents batch, a re-read line, a
    /// second evaluation of the same state, two evaluations at once): one incident, one notification.
    @Test func m9ScenarioSameEventTwiceGivesOneNotification() async throws {
        let s = Scratch()
        _ = runningCodex(s)
        let st = try store(s)
        let engine = codexEngine(s, store: st)
        let path = s.url.appendingPathComponent(Self.rollout("c-run")).path
        _ = await passes(engine, from: at("09:10:00"), to: at("09:34:00"))
        let first = await engine.pass(now: at("09:36:00"), scope: .paths([path]))
        let again = await engine.pass(now: at("09:36:10"), scope: .paths([path]))
        #expect(items(first, .stalledThread).map(\.id) == items(again, .stalledThread).map(\.id))
        let sent = ScriptedSender(answers: [])
        let dispatcher = NotificationDispatcher(store: st, send: sent.send)
        let input = NotificationPlanner.Input(projects: again.projects, settings: Self.on, now: at("09:36:10"))
        async let a = dispatcher.evaluate(input)
        async let b = dispatcher.evaluate(input)
        _ = await (a, b)
        _ = await dispatcher.evaluate(input)
        #expect(sent.count == 1)
    }

    /// Scenario 6: the agent completes while Lighthouse is down. On restart the turn is idle, the
    /// stall that was open resolves, and nothing new is notified.
    @Test func m9ScenarioCompletionDuringRestartResolvesWithoutAlert() async throws {
        let s = Scratch()
        _ = runningCodex(s, id: "c-done")
        let url = s.url.appendingPathComponent("app/lighthouse.sqlite")
        do {
            let st = try Store(url: url)
            let snapshot = await passes(codexEngine(s, store: st), from: at("09:10:00"), to: at("09:36:00"))
            #expect(items(snapshot, .stalledThread).count == 1)
            #expect(try await notify(snapshot, st, now: at("09:36:00")).count == 1)
        }
        s.append(Self.rollout("c-done"), Self.event("task_complete", "09:40:00"))
        let st = try Store(url: url)
        let snapshot = await codexEngine(s, store: st).pass(now: at("09:45:00"))
        #expect(snapshot.projects.first?.threads.first?.state == .idle)
        #expect(snapshot.projects.flatMap(\.attentionItems).isEmpty)
        #expect(try await notify(snapshot, st, now: at("09:45:00")).isEmpty)
    }

    /// Scenario 5 (Codex side): a Codex tool call is not progress, and Codex tool calls
    /// are expected to be short, so no Codex busy gate was added. A Codex turn that is truly silent for 30 min still stalls once.
    @Test func m9ScenarioCodexSilentTurnStillStallsOnce() async throws {
        let s = Scratch()
        _ = runningCodex(s)
        let snapshot = await passes(codexEngine(s), from: at("09:10:00"), to: at("10:30:00"))
        #expect(items(snapshot, .stalledThread).count == 1)
    }
}
