import Foundation
import Testing
@testable import LighthouseCore

/// M9 fixes whose tests use only APIs that exist at `fadab14`, so they compile there and fail on
/// behaviour (docs/reliability/test-logs). Test data only, never live state.
extension M4Tests {
    // MARK: F1 busy gate: a tool call T3 shows in flight is not a stall (owner scenario 5)

    /// T3's `turn_items` table schema, with its partial index.
    func addTurnItems(_ t3: T3Fixture) {
        t3.exec("""
            CREATE TABLE IF NOT EXISTS orchestration_v2_projection_turn_items (turn_item_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL,
              run_id TEXT, node_id TEXT, provider_thread_id TEXT, provider_turn_id TEXT, parent_item_id TEXT, ordinal INTEGER NOT NULL,
              type TEXT NOT NULL, status TEXT NOT NULL, updated_at TEXT NOT NULL, payload_json TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS orchestration_v2_projection_turn_items_recovery_idx ON orchestration_v2_projection_turn_items(thread_id)
              WHERE type IN ('command_execution', 'dynamic_tool', 'subagent') AND status IN ('pending', 'running', 'waiting');
            """)
    }

    /// One turn item; its payload carries the body canary in `input`, as a real command does.
    func turnItem(_ t3: T3Fixture, _ id: String, thread: String, run: String, type: String = "command_execution",
                  status: String = "running", started: Date) {
        let stamp = T3Fixture.iso(started)
        let payload = #"{"id":"\#(id)","startedAt":"\#(stamp)","status":"\#(status)","type":"\#(type)","input":"\#(Fixture.bodyCanary)"}"#
        t3.exec("""
            INSERT INTO orchestration_v2_projection_turn_items (turn_item_id, thread_id, run_id, ordinal, type, status, updated_at, payload_json)
            VALUES (\(T3Fixture.q(id)), \(T3Fixture.q(thread)), \(T3Fixture.q(run)), 1, \(T3Fixture.q(type)), \(T3Fixture.q(status)),
              '\(stamp)', \(T3Fixture.q(payload)))
            """)
    }

    /// A running T3 thread (Codex alias, last progress 09:05) whose run has a tool call in flight since 09:06.
    func busyT3(_ s: Scratch, store: Store? = nil) -> (T3Fixture, Engine) {
        let cwd = runningCodex(s, id: "c-busy", originator: "T3 Code")
        let t3 = T3Fixture(s)
        t3.project("p", title: "P", root: cwd)
        t3.thread("T1", project: "p", title: "Long build", created: at("09:00:00"))
        t3.mapping(thread: "T1", driver: "codex", nativeId: "c-busy")
        t3.run(thread: "T1", ordinal: 1, status: "running", requested: at("09:00:00"))
        addTurnItems(t3)
        turnItem(t3, "item-1", thread: "T1", run: "run-T1-1", started: at("09:06:00"))
        let engine = Engine(collectors: [CodexCollector(codexHome: s.codexHome, store: store)], store: store, home: s.path,
                            t3: T3Collector(reader: T3Reader(t3Home: t3.home), minInterval: 0))
        return (t3, engine)
    }

    /// fadab14 raises a stall at 09:35 while the command still runs (a false alarm).
    @Test func m9ToolCallInFlightIsNotAStallUntilTheCap() async throws {
        let s = Scratch()
        let (_, engine) = busyT3(s)
        var snapshot = await passes(engine, from: at("09:10:00"), to: at("11:02:00"))
        #expect(snapshot.projects.first?.threads.first?.state == .running)
        #expect(items(snapshot, .stalledThread).isEmpty)
        // The cap (2 h from 09:06) ends the exemption at 11:06; the stall then needs 30 min of
        // observed time, and keeps the identity of the evidence (09:05 + 30 min).
        snapshot = await passes(engine, from: at("11:06:00"), to: at("11:34:00"))
        #expect(items(snapshot, .stalledThread).isEmpty)
        snapshot = await engine.pass(now: at("11:37:00"))
        #expect(items(snapshot, .stalledThread).map(\.id) == ["stalledThread|t3:T1|\(Int(at("09:35:00").timeIntervalSince1970))"])
    }

    /// When the tool call ends, the reply that follows gets 30 min of observed time.
    @Test func m9EndOfAToolCallRestartsTheSilenceClock() async throws {
        let s = Scratch()
        let (t3, engine) = busyT3(s)
        var snapshot = await passes(engine, from: at("09:10:00"), to: at("09:50:00"))
        #expect(items(snapshot, .stalledThread).isEmpty)
        t3.exec("UPDATE orchestration_v2_projection_turn_items SET status = 'completed', updated_at = '\(T3Fixture.iso(at("09:51:00")))'")
        snapshot = await passes(engine, from: at("09:54:00"), to: at("10:22:00"))
        #expect(items(snapshot, .stalledThread).isEmpty)
        snapshot = await passes(engine, from: at("10:26:00"), to: at("10:30:00"))
        #expect(items(snapshot, .stalledThread).count == 1)
    }

    /// A delegated child running a long command is neither silent nor a reason to stall its parent.
    @Test func m9BusySubagentIsNotSilentAndExemptsItsParent() async throws {
        let s = Scratch()
        let cwd = runningCodex(s, id: "c-par", originator: "T3 Code")
        let t3 = T3Fixture(s)
        t3.project("p", title: "P", root: cwd)
        t3.thread("T1", project: "p", title: "Parent", created: at("09:00:00"))
        t3.mapping(thread: "T1", driver: "codex", nativeId: "c-par")
        t3.run(thread: "T1", ordinal: 1, status: "running", requested: at("09:00:00"))
        t3.thread("K1", project: "p", title: "coder", created: at("09:06:00"), parent: "T1")
        t3.subagent("sa", parent: "T1", child: "K1", provider: "codex", status: "running", started: at("09:06:00"), updated: at("09:07:00"))
        t3.run(thread: "K1", ordinal: 1, status: "running", requested: at("09:06:00"))
        addTurnItems(t3)
        turnItem(t3, "item-k", thread: "K1", run: "run-K1-1", started: at("09:08:00"))
        let engine = Engine(collectors: [CodexCollector(codexHome: s.codexHome)], store: nil, home: s.path,
                            t3: T3Collector(reader: T3Reader(t3Home: t3.home), minInterval: 0))
        let snapshot = await passes(engine, from: at("09:10:00"), to: at("10:40:00"))
        #expect(snapshot.projects.flatMap(\.attentionItems).isEmpty)
    }

    // MARK: F2 delivery claim: a crash after macOS accepted does not resend at once (owner scenario 7)

    /// The run "crashes" after macOS accepted the notification and before the result was stored:
    /// the sender accepts, then every later write fails. fadab14 sends it again at restart.
    @Test func m9CrashAfterAcceptanceDoesNotResendAtRestart() async throws {
        let s = Scratch()
        let st = try store(s)
        let flaky = FlakyLedgerStore(st)
        let t0 = at("10:00:00")
        let input = { (now: Date) in NotificationPlanner.Input(projects: [self.waitingProject(["req-1"], at: t0)], settings: Self.on, now: now) }
        let sent = ScriptedSender(answers: [])
        let crashing = NotificationDispatcher(store: flaky, send: { planned in
            _ = await sent.send(planned)
            flaky.failWrites = true   // the process dies here
            return true
        })
        _ = await crashing.evaluate(input(t0))
        #expect(sent.count == 1)
        // Restart a few seconds later: the counted attempt holds the retry back.
        let restarted = NotificationDispatcher(store: try Store(url: st.url), send: sent.send)
        _ = await restarted.evaluate(input(t0.addingTimeInterval(5)))
        #expect(sent.count == 1)
        let record = try #require(try st.loadNotificationLedger()["waitingForOwner|t3:T1|req-1"])
        #expect(record.attempts == 1 && record.lastAttemptAt == t0)
    }

    // MARK: R1 the restored launch shelf is not an observation (found in a relaunch test)

    /// At relaunch the restored shelf is built from checkpoints before any source or T3 read.
    /// fadab14 computed stalls on it as if observed forever, and the app notified from it: a T3
    /// thread's Codex alias, not yet merged, was alerted as a stalled Codex thread.
    @Test func m9RestoredLaunchShelfRaisesNoStall() async throws {
        let s = Scratch()
        _ = runningCodex(s)
        let url = s.url.appendingPathComponent("app/lighthouse.sqlite")
        do {
            let st = try Store(url: url)
            let engine = codexEngine(s, store: st)
            var snapshot = await passes(engine, from: at("09:10:00"), to: at("09:34:00"))
            // A line that is not progress, so the stored checkpoint was read moments before the "crash".
            s.append(Self.rollout("c-run"), Self.event("agent_reasoning", "09:35:50"))
            snapshot = await engine.pass(now: at("09:36:00"))
            #expect(items(snapshot, .stalledThread).count == 1)
        }
        let restored = await codexEngine(s, store: try Store(url: url)).restoredSnapshot(now: at("09:37:00"))
        #expect(!restored.projects.isEmpty)
        #expect(restored.projects.flatMap(\.attentionItems).isEmpty)
    }

    // MARK: R2 an open incident stays open across a gap (found in a freeze test)

    /// fadab14 hid an open stall for 30 min after any gap > 5 min (sleep, a hang), then showed it
    /// again under the same identity. The owner lost sight of an open incident in between.
    @Test func m9OpenStallStaysOpenAcrossAGap() async throws {
        let s = Scratch()
        _ = runningCodex(s)
        let engine = codexEngine(s)
        var snapshot = await passes(engine, from: at("09:10:00"), to: at("09:40:00"))
        let open = items(snapshot, .stalledThread).map(\.id)
        #expect(open.count == 1)
        // Wake after 80 min: no progress meanwhile, the same incident is still open.
        snapshot = await engine.pass(now: at("11:00:00"))
        #expect(items(snapshot, .stalledThread).map(\.id) == open)
        // New progress clears it; a gap does not bring it back.
        s.append(Self.rollout("c-run"), Self.tokens(150, "11:02:00"))
        snapshot = await engine.pass(now: at("11:03:00"))
        #expect(items(snapshot, .stalledThread).isEmpty)
        snapshot = await engine.pass(now: at("11:20:00"))
        #expect(items(snapshot, .stalledThread).isEmpty)
    }
}
