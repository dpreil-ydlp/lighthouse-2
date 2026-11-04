import Foundation
import Testing
@testable import LighthouseCore

/// SPEC 2.14 (owner 2026-11-04: "If I settle it, it should be out of there"): a T3 thread the owner
/// settled hides every attention item that entered at or before its `settledAt`. Fixture data only.
@Suite struct SettledTests {
    let fast = FastBadgeTests()
    func at(_ time: String) -> Date { fast.at(time) }

    func counted(_ snapshot: Snapshot) -> [String] { snapshot.projects.flatMap(\.attentionItems).map(\.id).sorted() }

    /// Parent T1 with its own request and a child T2 with a request, both entered at 09:01.
    func requests(_ s: Scratch) -> T3Fixture {
        let t3 = fast.parentWaiting(s)
        t3.thread("T2", project: "p", title: "Child", created: at("09:00:30"), parent: "T1")
        t3.run(thread: "T2", ordinal: 1, status: "running", requested: at("09:00:30"))
        t3.subagent("s1", parent: "T1", child: "T2", provider: "codex", status: "running", started: at("09:00:30"), updated: at("09:01:00"))
        t3.request("req-c", thread: "T2", kind: "user-input", created: at("09:01:00"))
        return t3
    }

    // MARK: C1 settled before: nothing counts

    @Test func settledThreadHidesItsAndItsChildsRequests() async throws {
        let s = Scratch()
        let t3 = requests(s)
        t3.settle("T1", at: at("09:01:30"))
        let (engine, _) = fast.makeEngine(t3, home: s.path)
        let snapshot = await engine.pass(now: at("09:02:00"))
        #expect(counted(snapshot).isEmpty)
        #expect(AttentionRules.counts(snapshot.projects).isEmpty)
        #expect(snapshot.projects.first?.status != .needsYou)
        #expect(snapshot.projects.first?.waitingThreads.isEmpty == true)
        #expect(await engine.t3Subjects.isEmpty)
    }

    @Test func settledThreadHidesItsReplyHandOff() async throws {
        let s = Scratch()
        let (t3, _) = fast.replyFixture(s)
        t3.settle("T1", at: at("09:05:30"))
        let (engine, _) = fast.makeEngine(t3, collectors: [CodexCollector(codexHome: s.codexHome)], home: s.path)
        let snapshot = await engine.pass(now: at("09:06:00"))
        #expect(counted(snapshot).isEmpty)
        #expect(snapshot.projects.flatMap(\.threads).first?.asksOwnerAt != nil)   // still detected, only hidden
    }

    /// The `FastBadgeTests.stalledNudged` thread (stall from 09:35, three nudges, handed to the owner
    /// at 10:15), settled at 10:20.
    @Test func settledThreadHidesItsStallAndExhaustedNudge() async throws {
        let s = Scratch()
        let cwd = s.dir("Projects/n")
        s.write(M4Tests.rollout("c-stall"), M4Tests.meta("c-stall", cwd: cwd, time: "09:00:00", originator: "T3 Code")
                + M4Tests.event("task_started", "09:00:01") + M4Tests.tokens(100, "09:05:00"))
        let t3 = T3Fixture(s)
        t3.project("p", title: "P", root: cwd)
        t3.thread("T1", project: "p", title: "Stuck", created: at("09:00:00"))
        t3.mapping(thread: "T1", driver: "codex", nativeId: "c-stall")
        t3.run(thread: "T1", ordinal: 1, status: "running", requested: at("09:00:00"))
        t3.settle("T1", at: at("10:20:00"))
        let collector = T3Collector(reader: T3Reader(t3Home: t3.home), minInterval: 0, subjectSpacing: 0)
        let engine = Engine(collectors: [CodexCollector(codexHome: s.codexHome)], store: nil, home: s.path, t3: collector)
        await engine.setNudges(["t3:T1": NudgeRecord(threadId: "T1", episodeStart: at("09:45:00"), count: 3, lastSentAt: at("10:00:00"))])
        var t = at("09:10:00")
        var last = await engine.pass(now: t)
        while t < at("10:30:00") {
            t = t.addingTimeInterval(240)
            last = await engine.pass(now: t)
        }
        #expect(counted(last).isEmpty)
        #expect(last.projects.flatMap(\.threads).first?.state == .running)
        // The episode began before the settle: it is over, so the thread carries no nudge mark.
        #expect(last.projects.flatMap(\.threads).first?.nudge == nil)
    }

    // MARK: Every kind, at the rule level

    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func thread(_ state: ThreadState, app: OwningApp = .t3) -> SessionThread {
        var t = SessionThread(id: "t3:A", owningApp: app, providerIdentities: [ProviderIdentity(provider: .codex, nativeId: "A")],
                              title: "A", cwd: "/x", state: state, sourceReadAt: now,
                              lastActivityAt: now.addingTimeInterval(-40 * 60), lastProgressAt: now.addingTimeInterval(-40 * 60))
        t.t3ThreadId = "A"
        return t
    }

    /// One thread per kind, each item entered before `now - 1 min`.
    func everyKind() -> [SessionThread] {
        var request = thread(.waitingForOwner)
        request.pendingRequest = PendingRequest(id: "r1", kind: "command", createdAt: now.addingTimeInterval(-20 * 60))
        var reply = thread(.stopped)
        reply.asksOwnerAt = now.addingTimeInterval(-20 * 60)
        var child = thread(.idle)
        var sub = Subagent(id: "t3:C", name: "child", provider: .codex, state: .waitingForOwner, sourceReadAt: now,
                           lastActivityAt: now.addingTimeInterval(-20 * 60))
        sub.pendingRequest = PendingRequest(id: "r2", kind: "user_input", createdAt: now.addingTimeInterval(-20 * 60))
        child.subagents = [sub]
        var silent = thread(.idle)
        silent.subagents = [Subagent(id: "t3:S", name: "quiet", provider: .codex, state: .running, sourceReadAt: now,
                                     lastActivityAt: now.addingTimeInterval(-40 * 60))]
        var stalled = thread(.running)
        stalled.runningSince = now.addingTimeInterval(-90 * 60)
        stalled.nudge = NudgeMark(count: 3, lastSentAt: now.addingTimeInterval(-20 * 60), episodeKey: "1")
        return [request, reply, child, silent, stalled]
    }

    @Test func everyKindEnteredAtOrBeforeTheSettleIsHidden() {
        let threads = everyKind()
        let open = threads.flatMap { AttentionRules.items(for: $0, now: now) }
        #expect(Set(open.map(\.kind)) == [.waitingForOwner, .silentSubagent, .stalledThread])
        #expect(open.count == 6)   // request, reply, child request, silent subagent, stall, exhausted nudge
        let latest = open.map(\.enteredAt).max()!
        for settle in [latest, now.addingTimeInterval(-60)] {   // the boundary itself, and later
            let settled = threads.map { t -> SessionThread in var t = t; t.settledAt = settle; return t }
            #expect(settled.flatMap { AttentionRules.items(for: $0, now: now) }.isEmpty)
        }
    }

    // MARK: C2 what still counts

    @Test func itemsThatEnterAfterTheSettleStillCount() {
        let threads = everyKind()
        let open = threads.flatMap { AttentionRules.items(for: $0, now: now) }
        let earliest = open.map(\.enteredAt).min()!
        let settled = threads.map { t -> SessionThread in var t = t; t.settledAt = earliest.addingTimeInterval(-1); return t }
        #expect(settled.flatMap { AttentionRules.items(for: $0, now: now) } == open)
    }

    @Test func aRequestAfterTheSettleCounts() async throws {
        let s = Scratch()
        let t3 = requests(s)
        t3.settle("T1", at: at("09:00:45"))
        let (engine, _) = fast.makeEngine(t3, home: s.path)
        #expect(counted(await engine.pass(now: at("09:02:00"))) == ["waitingForOwner|t3:T1|req-1", "waitingForOwner|t3:T2|req-c"])
    }

    @Test func unsettledAndInvalidPayloadThreadsCountAsBefore() async throws {
        let s = Scratch()
        let t3 = requests(s)
        t3.settle("T1", at: at("09:01:30"))
        t3.unsettle("T1", at: at("09:01:40"))
        let (engine, _) = fast.makeEngine(t3, home: s.path)
        let expected = ["waitingForOwner|t3:T1|req-1", "waitingForOwner|t3:T2|req-c"]
        #expect(counted(await engine.pass(now: at("09:02:00"))) == expected)
        let state = try T3Reader(t3Home: t3.home).read().get()
        #expect(state.threads.allSatisfy { $0.settledAt == nil })

        // A payload that is not JSON is not settled (and does not fail the read).
        let s2 = Scratch()
        let t3b = requests(s2)
        t3b.exec("UPDATE orchestration_v2_projection_threads SET payload_json = 'not json settledOverride settled' WHERE thread_id = 'T1'")
        let (engine2, _) = fast.makeEngine(t3b, home: s2.path)
        #expect(counted(await engine2.pass(now: at("09:02:00"))) == expected)
    }

    @Test func fullReadCarriesTheSettleMark() throws {
        let s = Scratch()
        let t3 = requests(s)
        t3.settle("T1", at: at("09:01:30"))
        let state = try T3Reader(t3Home: t3.home).read().get()
        #expect(state.threads.first { $0.id == "T1" }?.settledAt == at("09:01:30"))
        #expect(state.threads.first { $0.id == "T2" }?.settledAt == nil)
    }

    // MARK: C3 fast path

    @Test func settlingACountedThreadClearsTheCountWithoutAFullRead() async throws {
        let s = Scratch()
        let t3 = fast.parentWaiting(s)
        let (engine, collector) = fast.makeEngine(t3, home: s.path)
        #expect(counted(await engine.pass(now: at("09:02:00"))) == ["waitingForOwner|t3:T1|req-1"])
        #expect(await engine.t3Subjects == ["T1"])

        t3.settle("T1", at: at("09:02:00"))
        #expect(await engine.refreshT3Subjects())
        let after = await engine.resolvedSnapshot(now: at("09:02:01"))
        #expect(counted(after).isEmpty)
        #expect(after.projects.first?.threads.first?.state == .waitingForOwner)   // the request itself is still pending
        #expect(await collector.reads == 1)
        #expect(await collector.subjectReads == 1)
        #expect(await engine.t3Subjects.isEmpty)
    }

    @Test func targetedSettleMatchesAFullRead() throws {
        let s = Scratch()
        let t3 = fast.parentWaiting(s)
        let reader = T3Reader(t3Home: t3.home)
        var patched = try reader.read().get()
        t3.settle("T1", at: at("09:02:00"))
        let subjects = try reader.readSubjects(["T1"]).get()
        #expect(subjects["T1"]?.settledAt == at("09:02:00"))
        #expect(T3Collector.apply(subjects, to: &patched))
        #expect(patched.threads == (try reader.read().get()).threads)
        // Unsettling patches it back.
        t3.unsettle("T1", at: at("09:03:00"))
        #expect(T3Collector.apply(try reader.readSubjects(["T1"]).get(), to: &patched))
        #expect(patched.threads.first?.settledAt == nil)
    }

    // MARK: Nudges

    @Test func settlingEndsTheNudgeEpisode() {
        var t = thread(.running)
        t.runningSince = now.addingTimeInterval(-90 * 60)
        let old = NudgeRecord(threadId: t.id, episodeStart: now.addingTimeInterval(-3 * 3600), count: 3, lastSentAt: now.addingTimeInterval(-2 * 3600))
        t.settledAt = now.addingTimeInterval(-2 * 3600)
        // The old episode is over: reconcile drops it, and the engine marks nothing from it.
        #expect(NudgePolicy.reconcile([t.id: old], threads: [t], now: now).removed == [t.id])
        #expect(NudgePolicy.current(old, settledAt: t.settledAt, now: now) == nil)
        // A stall that entered after the settle is a new episode: nudge 1, not a 4th of the old one.
        let identity = ProjectIdentity(root: "/P/a", name: "a", kind: .git)
        let project = ShelfBuilder.summarize(threads: [t], identities: [identity], now: now)[0]
        let next = NudgePolicy.next([project], records: [t.id: old], now: now)
        #expect(next?.number == 1)
        #expect(next?.episodeStart == now)
        // An episode that began after the settle keeps its count.
        let later = NudgeRecord(threadId: t.id, episodeStart: now.addingTimeInterval(-30 * 60), count: 1, lastSentAt: now.addingTimeInterval(-30 * 60))
        #expect(NudgePolicy.reconcile([t.id: later], threads: [t], now: now).records[t.id] == later)
        #expect(NudgePolicy.next([project], records: [t.id: later], now: now)?.number == 2)
    }

    @Test func noNudgeForAStallFromBeforeTheSettle() {
        var t = thread(.running)
        t.runningSince = now.addingTimeInterval(-90 * 60)
        t.settledAt = now.addingTimeInterval(-60)   // the stall entered 10 min ago
        let identity = ProjectIdentity(root: "/P/a", name: "a", kind: .git)
        let project = ShelfBuilder.summarize(threads: [t], identities: [identity], now: now)[0]
        #expect(NudgePolicy.next([project], records: [:], now: now) == nil)
    }
}
