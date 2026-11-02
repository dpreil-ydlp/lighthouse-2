import Foundation
import Testing
@testable import LighthouseCore

/// SPEC §11 M4: §5.4 stall rules, observed-time gating, §8 notifications (one per incident,
/// persisted, coalesced, paused), usage alerts, keyboard focus over usage rows and project pages.
@Suite struct M4Tests {
    func at(_ time: String) -> Date { Fixture.date("2026-10-29T\(time).000Z") }

    // MARK: Fixture helpers (test data only, never live state)

    static func meta(_ id: String, cwd: String, time: String, originator: String? = nil) -> String {
        let origin = originator.map { #","originator":"\#($0)""# } ?? ""
        return #"{"timestamp":"2026-10-29T\#(time).000Z","type":"session_meta","payload":{"id":"\#(id)","cwd":"\#(cwd)"\#(origin)}}"# + "\n"
    }
    static func event(_ type: String, _ time: String) -> String {
        #"{"timestamp":"2026-10-29T\#(time).000Z","type":"event_msg","payload":{"type":"\#(type)"}}"# + "\n"
    }
    static func tokens(_ total: Int, _ time: String) -> String {
        #"{"timestamp":"2026-10-29T\#(time).000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":\#(total)}}}}"# + "\n"
    }
    static func rollout(_ id: String) -> String { "codex/sessions/2026/10/29/rollout-2026-10-29T09-00-00-\(id).jsonl" }

    /// A running Codex session: started 09:00, one real token increase at 09:05.
    func runningCodex(_ s: Scratch, id: String = "c-run", cwd: String? = nil, originator: String? = nil) -> String {
        let cwd = cwd ?? s.dir("Projects/alpha")
        s.write(Self.rollout(id), Self.meta(id, cwd: cwd, time: "09:00:00", originator: originator)
                + Self.event("task_started", "09:00:01") + Self.tokens(100, "09:05:00"))
        return cwd
    }

    func codexEngine(_ s: Scratch, store: Store? = nil, access: SourceAccess = ReadOnlyFileSystem()) -> Engine {
        Engine(collectors: [CodexCollector(codexHome: s.codexHome, access: access, store: store)], store: store, home: s.path)
    }

    /// Passes every 4 min (inside the 5 min gap bound) from `from` through `to`; returns the last.
    func passes(_ engine: Engine, from: Date, to: Date, step: TimeInterval = 240) async -> Snapshot {
        var t = from
        var last = await engine.pass(now: t)
        while t < to {
            t = min(t.addingTimeInterval(step), to)
            last = await engine.pass(now: t)
        }
        return last
    }

    static var on: AppSettings {
        var settings = AppSettings()
        settings.notificationsOn = true
        return settings
    }

    /// One planner evaluation against the persisted ledger, as the app runs it.
    /// Repair round 1: through `NotificationDispatcher` (durable pending record, then submit, then
    /// mark submitted), with a sender that accepts everything. A new dispatcher per call loads the
    /// ledger from the store, as after a restart. Returns the notifications macOS "accepted".
    func notify(_ snapshot: Snapshot, _ store: Store, settings: AppSettings = M4Tests.on, now: Date,
                usage: [ProviderUsage] = []) async throws -> [PlannedNotification] {
        let alerts = UsageAlerts.thresholdAlerts(usage, now: now)
        let dispatcher = NotificationDispatcher(store: store, send: { _ in true })
        let report = await dispatcher.evaluate(.init(projects: snapshot.projects, usageAlerts: alerts.deliver, usageCovered: alerts.covered,
                                                     settings: settings, now: now))
        #expect(!report.ledgerUnavailable)
        return report.submitted
    }

    func items(_ snapshot: Snapshot, _ kind: AttentionKind) -> [AttentionItem] {
        snapshot.projects.flatMap(\.attentionItems).filter { $0.kind == kind }
    }

    func store(_ s: Scratch) throws -> Store { try Store(url: s.url.appendingPathComponent("app/lighthouse.sqlite")) }

    // MARK: C1 — no stall: completed turn, approval wait, unreadable source, sleep/wake, recovery, repeated observation

    @Test func completedTurnRaisesNoStall() async throws {
        let s = Scratch()
        _ = runningCodex(s)
        s.append(Self.rollout("c-run"), Self.event("task_complete", "09:06:00"))
        let snapshot = await codexEngine(s).pass(now: at("10:30:00"))
        #expect(snapshot.projects.first?.threads.first?.state == .idle)
        #expect(snapshot.projects.flatMap(\.attentionItems).isEmpty)
    }

    @Test func approvalWaitRaisesWaitingNotStall() async throws {
        let s = Scratch()
        let cwd = runningCodex(s, id: "c-wait", originator: "T3 Code")
        let t3 = T3Fixture(s)
        t3.project("p", title: "P", root: cwd)
        t3.thread("T1", project: "p", title: "Wait thread", created: at("09:00:00"))
        t3.mapping(thread: "T1", driver: "codex", nativeId: "c-wait")
        t3.run(thread: "T1", ordinal: 1, status: "running", requested: at("09:00:00"))
        t3.request("req-1", thread: "T1", kind: "command", created: at("09:06:00"))
        let engine = Engine(collectors: [CodexCollector(codexHome: s.codexHome)], store: nil, home: s.path,
                            t3: T3Collector(reader: T3Reader(t3Home: t3.home), minInterval: 0))
        let snapshot = await engine.pass(now: at("10:30:00"))
        let thread = try #require(snapshot.projects.first?.threads.first)
        #expect(thread.state == .waitingForOwner)
        #expect(items(snapshot, .waitingForOwner).map(\.id) == ["waitingForOwner|t3:T1|req-1"])
        #expect(items(snapshot, .stalledThread).isEmpty)
    }

    @Test func unreadableSourceRaisesNoStall() async throws {
        let s = Scratch()
        _ = runningCodex(s)
        let access = RecordingAccess()
        let engine = codexEngine(s, access: access)
        _ = await engine.pass(now: at("09:10:00"))
        access.deny(s.codexHome)
        let snapshot = await passes(engine, from: at("09:14:00"), to: at("10:30:00"))
        #expect(snapshot.projects.flatMap(\.threads).allSatisfy { $0.state == .unknown })
        #expect(snapshot.projects.flatMap(\.attentionItems).isEmpty)
        #expect(snapshot.statuses.first { $0.source == .codex }?.error != nil)
    }

    /// The Mac sleeps 09:20–11:00: the 100 min without a pass never counts as observed silence.
    @Test func sleepWakeGapIsNotSilence() async throws {
        let s = Scratch()
        _ = runningCodex(s)
        let engine = codexEngine(s)
        _ = await passes(engine, from: at("09:10:00"), to: at("09:20:00"))
        // Wake: 115 min since the last progress, but only just observed again.
        var snapshot = await engine.pass(now: at("11:00:00"))
        #expect(snapshot.projects.first?.threads.first?.state == .running)
        #expect(items(snapshot, .stalledThread).isEmpty)
        snapshot = await passes(engine, from: at("11:04:00"), to: at("11:28:00"))
        #expect(items(snapshot, .stalledThread).isEmpty)
        // After 30 min of observed silence the stall is raised, keyed on the evidence time (09:05 + 30 min).
        snapshot = await engine.pass(now: at("11:31:00"))
        #expect(items(snapshot, .stalledThread).map(\.id) == ["stalledThread|codex:c-run|\(Int(at("09:35:00").timeIntervalSince1970))"])
    }

    /// T3 is unreadable 09:21–09:31; on recovery the silence clock restarts.
    @Test func recoveryRestartsTheSilenceClock() async throws {
        let s = Scratch()
        let cwd = runningCodex(s, id: "c-rec", originator: "T3 Code")
        let t3 = T3Fixture(s)
        t3.project("p", title: "P", root: cwd)
        t3.thread("T1", project: "p", title: "Recovering", created: at("09:00:00"))
        t3.mapping(thread: "T1", driver: "codex", nativeId: "c-rec")
        t3.run(thread: "T1", ordinal: 1, status: "running", requested: at("09:00:00"))
        t3.close()
        let access = RecordingAccess()
        let engine = Engine(collectors: [CodexCollector(codexHome: s.codexHome)], store: nil, home: s.path,
                            t3: T3Collector(reader: T3Reader(t3Home: t3.home, access: access), minInterval: 0))
        _ = await passes(engine, from: at("09:12:00"), to: at("09:20:00"))
        access.deny(t3.home)
        var snapshot = await passes(engine, from: at("09:24:00"), to: at("09:28:00"))
        #expect(snapshot.projects.flatMap(\.threads).first { $0.t3ThreadId == "T1" }?.state == .unknown)
        #expect(items(snapshot, .stalledThread).isEmpty)
        access.allowAll()
        // 35 min after the last progress, but T3 was just read again: no stall yet.
        snapshot = await engine.pass(now: at("09:32:00"))
        #expect(snapshot.projects.flatMap(\.threads).first { $0.t3ThreadId == "T1" }?.state == .running)
        #expect(items(snapshot, .stalledThread).isEmpty)
        snapshot = await passes(engine, from: at("09:36:00"), to: at("10:00:00"))
        #expect(items(snapshot, .stalledThread).isEmpty)
        snapshot = await passes(engine, from: at("10:02:00"), to: at("10:03:00"))
        #expect(items(snapshot, .stalledThread).count == 1)
    }

    /// Nearest wrong result: an item or notification on every poll of an unchanged silent thread.
    @Test func unchangedRepeatedObservationIsNoProgressAndOneIncident() async throws {
        let s = Scratch()
        _ = runningCodex(s)
        for time in ["09:10:00", "09:20:00", "09:29:00"] { s.append(Self.rollout("c-run"), Self.tokens(100, time)) }
        let st = try store(s)
        let engine = codexEngine(s, store: st)
        var snapshot = await passes(engine, from: at("09:10:00"), to: at("09:34:00"), step: 120)
        let thread = try #require(snapshot.projects.first?.threads.first)
        #expect(thread.lastProgressAt == at("09:05:00"))
        #expect(thread.lastActivityAt == at("09:29:00"))
        // 09:34: 29 min since the last real progress: no stall despite the repeated observations.
        #expect(items(snapshot, .stalledThread).isEmpty)
        var delivered: [PlannedNotification] = []
        var ids = Set<String>()
        var t = at("09:36:00")
        while t <= at("10:20:00") {
            s.append(Self.rollout("c-run"), Self.tokens(100, Self.clock(t)))
            snapshot = await engine.pass(now: t.addingTimeInterval(30))
            ids.formUnion(items(snapshot, .stalledThread).map(\.id))
            delivered += try await notify(snapshot, st, now: t.addingTimeInterval(30))
            t = t.addingTimeInterval(120)
        }
        #expect(ids == ["stalledThread|codex:c-run|\(Int(at("09:35:00").timeIntervalSince1970))"])
        #expect(delivered.count == 1)
    }

    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    // MARK: C2 — proven-running T3 thread: one item, one notification; progress clears; new silence is new

    @Test func runningT3ThreadStallsOnceClearsOnProgressAndStallsAgainAsANewIncident() async throws {
        let s = Scratch()
        let cwd = runningCodex(s, id: "c-t3", originator: "T3 Code")
        let t3 = T3Fixture(s)
        t3.project("p", title: "Recipes", root: cwd)
        t3.thread("T1", project: "p", title: "Recipe card layout", created: at("09:00:00"))
        t3.mapping(thread: "T1", driver: "codex", nativeId: "c-t3")
        t3.run(thread: "T1", ordinal: 1, status: "running", requested: at("09:00:00"))
        t3.close()
        let st = try store(s)
        let engine = Engine(collectors: [CodexCollector(codexHome: s.codexHome, store: st)], store: st, home: s.path,
                            t3: T3Collector(reader: T3Reader(t3Home: t3.home), minInterval: 0))

        var snapshot = await passes(engine, from: at("09:10:00"), to: at("09:34:00"))
        #expect(items(snapshot, .stalledThread).isEmpty)
        #expect(try await notify(snapshot, st, now: at("09:34:00")).isEmpty)

        // 31 min without progress: one item and one notification.
        snapshot = await engine.pass(now: at("09:36:00"))
        let first = try #require(items(snapshot, .stalledThread).first)
        #expect(items(snapshot, .stalledThread).count == 1)
        #expect(first.id == "stalledThread|t3:T1|\(Int(at("09:35:00").timeIntervalSince1970))")
        #expect(first.label == "No progress · Recipe card layout")
        #expect(snapshot.projects[0].attention == ["1 thread stalled · 31 m"])
        let sent = try await notify(snapshot, st, now: at("09:36:00"))
        #expect(sent.count == 1)
        #expect(sent.first?.title == "Gone quiet · Recipes")
        #expect(sent.first?.projectRoot == snapshot.projects[0].identity.root)
        // Polling the unchanged silent thread: the same item, no further notification.
        snapshot = await passes(engine, from: at("09:38:00"), to: at("09:40:00"))
        #expect(items(snapshot, .stalledThread).map(\.id) == [first.id])
        #expect(try await notify(snapshot, st, now: at("09:40:00")).isEmpty)

        // Acknowledge, then new progress clears the condition while the thread stays running.
        try st.acknowledge(first.id)
        s.append(Self.rollout("c-t3"), Self.tokens(250, "09:41:00"))
        snapshot = await engine.pass(now: at("09:42:00"))
        let thread = try #require(snapshot.projects.first?.threads.first)
        #expect(thread.state == .running)
        #expect(thread.lastProgressAt == at("09:41:00"))
        #expect(items(snapshot, .stalledThread).isEmpty)

        // A second 30 min silence is a new incident with one new notification, despite the acknowledgement.
        snapshot = await passes(engine, from: at("09:46:00"), to: at("10:10:00"))
        #expect(items(snapshot, .stalledThread).isEmpty)
        snapshot = await engine.pass(now: at("10:12:00"))
        let second = try #require(items(snapshot, .stalledThread).first)
        #expect(second.id == "stalledThread|t3:T1|\(Int(at("10:11:00").timeIntervalSince1970))")
        #expect(second.id != first.id)
        #expect(try await notify(snapshot, st, now: at("10:12:00")).count == 1)
        #expect(try await notify(snapshot, st, now: at("10:14:00")).isEmpty)
    }

    // MARK: C3 — Codex progress: a real total increase advances progress; a repeated total does not

    @Test func codexTotalIncreaseAdvancesProgressAndRepeatedTotalDoesNot() async throws {
        let s = Scratch()
        _ = runningCodex(s)
        let engine = codexEngine(s)
        var thread = try #require(await engine.pass(now: at("09:10:00")).projects.first?.threads.first)
        #expect(thread.state == .running)
        #expect(thread.lastProgressAt == at("09:05:00"))
        s.append(Self.rollout("c-run"), Self.tokens(100, "09:12:00"))
        thread = try #require(await engine.pass(now: at("09:13:00")).projects.first?.threads.first)
        #expect(thread.lastProgressAt == at("09:05:00"))
        #expect(AttentionRules.progressReference(of: thread) == at("09:05:00"))
        s.append(Self.rollout("c-run"), Self.tokens(140, "09:14:00"))
        thread = try #require(await engine.pass(now: at("09:15:00")).projects.first?.threads.first)
        #expect(thread.lastProgressAt == at("09:14:00"))
        #expect(AttentionRules.progressReference(of: thread) == at("09:14:00"))
    }

    /// A new turn after old progress: the stall clock starts at `task_started`, not at the old progress.
    @Test func newTurnStartsTheStallClock() async throws {
        let s = Scratch()
        _ = runningCodex(s)
        s.append(Self.rollout("c-run"), Self.event("task_complete", "09:06:00") + Self.event("task_started", "10:00:00"))
        let snapshot = await codexEngine(s).pass(now: at("10:20:00"))
        let thread = try #require(snapshot.projects.first?.threads.first)
        #expect(thread.state == .running)
        #expect(thread.runningSince == at("10:00:00"))
        #expect(items(snapshot, .stalledThread).isEmpty)
    }

    /// A parent quiet while its subagent works is waiting on it: the subagent's silence rule
    /// covers it, so one item, never a parent stall as well.
    @Test func parentWaitingOnARunningSubagentIsNotStalled() async throws {
        let s = Scratch()
        let cwd = runningCodex(s, id: "c-par", originator: "T3 Code")
        let t3 = T3Fixture(s)
        t3.project("p", title: "P", root: cwd)
        t3.thread("T1", project: "p", title: "Parent", created: at("09:00:00"))
        t3.mapping(thread: "T1", driver: "codex", nativeId: "c-par")
        t3.run(thread: "T1", ordinal: 1, status: "running", requested: at("09:00:00"))
        t3.thread("K1", project: "p", title: "coder", created: at("09:06:00"), parent: "T1")
        t3.subagent("sa", parent: "T1", child: "K1", provider: "codex", status: "running", started: at("09:06:00"), updated: at("09:50:00"))
        // Repair round 1 (M4-R06): the child makes real progress (a token increase at 09:50), so
        // it exempts the parent; activity alone would not.
        t3.mapping(thread: "K1", driver: "codex", nativeId: "c-kid")
        s.write(Self.rollout("c-kid"), Self.meta("c-kid", cwd: cwd, time: "09:06:00", originator: "T3 Code")
                + Self.event("task_started", "09:06:00") + Self.tokens(50, "09:06:30") + Self.tokens(120, "09:50:00"))
        let engine = Engine(collectors: [CodexCollector(codexHome: s.codexHome)], store: nil, home: s.path,
                            t3: T3Collector(reader: T3Reader(t3Home: t3.home), minInterval: 0))
        var snapshot = await passes(engine, from: at("09:30:00"), to: at("10:10:00"))
        #expect(snapshot.projects.flatMap(\.attentionItems).isEmpty)
        // The child goes silent: one silent-subagent item, still no parent stall.
        snapshot = await passes(engine, from: at("10:14:00"), to: at("10:22:00"))
        #expect(items(snapshot, .silentSubagent).count == 1)
        #expect(items(snapshot, .stalledThread).isEmpty)
        // The child completes at 10:23 (progress of the parent) and the parent then stays quiet:
        // a parent stall 30 min after the completion, keyed on it.
        t3.exec("UPDATE orchestration_v2_projection_subagents SET status = 'completed', completed_at = '\(T3Fixture.iso(at("10:23:00")))'")
        snapshot = await passes(engine, from: at("10:24:00"), to: at("10:52:00"))
        #expect(items(snapshot, .stalledThread).isEmpty)
        snapshot = await engine.pass(now: at("10:54:00"))
        #expect(items(snapshot, .stalledThread).map(\.id) == ["stalledThread|t3:T1|\(Int(at("10:53:00").timeIntervalSince1970))"])
    }

    // MARK: C4 — Claude Code-owned threads: "Stall detection unavailable", never a stall

    @Test func claudeCodeThreadNeverStalls() async throws {
        let long = at("07:00:00")
        var thread = SessionThread(id: "claude:x", owningApp: .claudeCode, providerIdentities: [ProviderIdentity(provider: .claude, nativeId: "x")],
                                   cwd: "/x", state: .running, sourceReadAt: at("10:00:00"), lastActivityAt: long, lastProgressAt: long)
        thread.runningSince = long
        // Running 3 h without progress: never a stall.
        #expect(AttentionRules.items(for: thread, now: at("10:00:00")).isEmpty)
        #expect(AttentionRules.stallNote(for: thread) == "Stall detection unavailable for Claude Code")
        // Its running subagent silent 3 h: never a silence either.
        thread.subagents = [Subagent(id: "a", name: "helper", provider: .claude, state: .running, sourceReadAt: at("10:00:00"), lastActivityAt: long)]
        #expect(AttentionRules.items(for: thread, now: at("10:00:00")).isEmpty)

        // Through the collector: a Claude session waiting on a tool result for 5 min, last assistant 2 h ago.
        let s = Scratch()
        let id = "33333333-3333-4333-8333-333333333333"
        s.write("claude/-Users-me-Projects-beta/\(id).jsonl",
                #"{"type":"assistant","sessionId":"\#(id)","cwd":"/Users/me/Projects/beta","timestamp":"2026-10-29T08:00:00.000Z","message":{"id":"msg_1","role":"assistant","stop_reason":"tool_use","usage":{"input_tokens":1,"output_tokens":1}}}"# + "\n" +
                #"{"type":"user","sessionId":"\#(id)","cwd":"/Users/me/Projects/beta","timestamp":"2026-10-29T09:55:00.000Z","message":{"role":"user"}}"# + "\n")
        let snapshot = await Engine(collectors: [ClaudeCodeCollector(root: s.claudeRoot)], store: nil, home: s.path).pass(now: at("10:00:00"))
        let claude = try #require(snapshot.projects.first?.threads.first)
        #expect(claude.owningApp == .claudeCode)
        #expect(claude.state == .running)
        #expect(snapshot.projects.flatMap(\.attentionItems).isEmpty)
        #expect(AttentionRules.stallNote(for: claude) == "Stall detection unavailable for Claude Code")
    }

    /// A running T3 thread with no readable provider session: coverage unknown, no stall.
    @Test func t3ThreadWithoutProviderSessionShowsCoverageUnknown() async throws {
        let s = Scratch()
        let t3 = T3Fixture(s)
        t3.project("p", title: "P", root: s.dir("Projects/p"))
        t3.thread("T1", project: "p", title: "No alias", created: at("08:00:00"))
        t3.run(thread: "T1", ordinal: 1, status: "running", requested: at("08:00:00"))
        let snapshot = await Engine(collectors: [], store: nil, home: s.path, t3: T3Collector(reader: T3Reader(t3Home: t3.home), minInterval: 0))
            .pass(now: at("10:00:00"))
        let thread = try #require(snapshot.projects.first?.threads.first)
        #expect(thread.state == .running)
        #expect(snapshot.projects.flatMap(\.attentionItems).isEmpty)
        #expect(AttentionRules.stallNote(for: thread) == "Coverage unknown")
    }

    // MARK: C5 — one notification per incident across restart; replacement request; coalescing

    @Test func oneNotificationPerIncidentAcrossRestart() async throws {
        let s = Scratch()
        _ = runningCodex(s)
        let url = s.url.appendingPathComponent("app/lighthouse.sqlite")
        do {
            let st = try Store(url: url)
            let snapshot = await passes(codexEngine(s, store: st), from: at("09:10:00"), to: at("09:36:00"))
            #expect(try await notify(snapshot, st, now: at("09:36:00")).count == 1)
        }
        // Restart: a new store connection and engine; the incident is the same and is not notified again.
        let st = try Store(url: url)
        let snapshot = await codexEngine(s, store: st).pass(now: at("09:50:00"))
        #expect(items(snapshot, .stalledThread).count == 1)
        #expect(try await notify(snapshot, st, now: at("09:50:00")).isEmpty)
        #expect(try st.loadNotificationLedger().values.filter(\.delivered).count == 1)
    }

    @Test func replacementT3RequestIsANewIncidentDeliveredAfterTheCoalescingWindow() async throws {
        let s = Scratch()
        let t3 = T3Fixture(s)
        t3.project("p", title: "P", root: s.dir("Projects/p"))
        t3.thread("T1", project: "p", title: "Asks", created: at("09:00:00"))
        t3.run(thread: "T1", ordinal: 1, status: "running", requested: at("09:00:00"))
        t3.request("req-1", thread: "T1", kind: "command", created: at("09:59:00"))
        let st = try store(s)
        let engine = Engine(collectors: [], store: st, home: s.path, t3: T3Collector(reader: T3Reader(t3Home: t3.home), minInterval: 0))
        var snapshot = await engine.pass(now: at("10:00:00"))
        var sent = try await notify(snapshot, st, now: at("10:00:00"))
        #expect(sent.map(\.incidents) == [["waitingForOwner|t3:T1|req-1"]])
        #expect(sent.first?.title == "Needs you · P")
        #expect(sent.first?.body == "Approval requested · Asks")

        // The request is replaced: a new incident. Within 5 min of the last delivery it waits.
        t3.exec("UPDATE orchestration_v2_projection_runtime_requests SET status = 'resolved', resolved_at = '\(T3Fixture.iso(at("10:01:00")))'")
        t3.request("req-2", thread: "T1", kind: "command", created: at("10:02:00"))
        snapshot = await engine.pass(now: at("10:03:00"))
        #expect(items(snapshot, .waitingForOwner).map(\.id) == ["waitingForOwner|t3:T1|req-2"])
        #expect(try await notify(snapshot, st, now: at("10:03:00")).isEmpty)
        snapshot = await engine.pass(now: at("10:05:30"))
        sent = try await notify(snapshot, st, now: at("10:05:30"))
        #expect(sent.map(\.incidents) == [["waitingForOwner|t3:T1|req-2"]])
        #expect(try await notify(snapshot, st, now: at("10:07:00")).isEmpty)
    }

    @Test func incidentsOfOneProjectCoalesceIntoOneNotification() throws {
        let now = at("10:00:00")
        func item(_ id: String, _ kind: AttentionKind, _ label: String) -> AttentionItem {
            AttentionItem(id: id, kind: kind, threadId: "t", enteredAt: now, label: label)
        }
        let a = ProjectSummary(identity: ProjectIdentity(root: "/a", name: "A", kind: .folder), threads: [], status: .needsYou, lastActivityAt: now,
                               attentionItems: [item("s1", .stalledThread, "No progress · one"), item("w1", .waitingForOwner, "Approval requested · two")])
        let b = ProjectSummary(identity: ProjectIdentity(root: "/b", name: "B", kind: .folder), threads: [], status: .needsYou, lastActivityAt: now,
                               attentionItems: [item("s2", .silentSubagent, "Subagent silent · coder")])
        var ledger: [String: NotificationRecord] = [:]
        var plan = NotificationPlanner.plan(.init(projects: [a, b], settings: Self.on, now: now), ledger: ledger)
        #expect(plan.deliver.count == 2)
        let first = try #require(plan.deliver.first { $0.projectRoot == "/a" })
        #expect(first.incidents == ["w1", "s1"])
        #expect(first.body == "Approval requested · two · and 1 more")
        // Repair round 1: planned deliveries come back pending; macOS accepting them marks them submitted.
        for var r in plan.record {
            if r.state == .pending { r.state = .submitted; r.attempts = 1; r.lastAttemptAt = now }
            ledger[r.incident] = r
        }
        // A new incident in A two minutes later is held, and dropped if it clears inside the window.
        var a2 = a
        a2.attentionItems.append(item("s3", .stalledThread, "No progress · three"))
        plan = NotificationPlanner.plan(.init(projects: [a2, b], settings: Self.on, now: now.addingTimeInterval(120)), ledger: ledger)
        #expect(plan.deliver.isEmpty && plan.record.isEmpty)
        plan = NotificationPlanner.plan(.init(projects: [a, b], settings: Self.on, now: now.addingTimeInterval(400)), ledger: ledger)
        #expect(plan.deliver.isEmpty)
    }

    // MARK: C6 — pause suppresses delivery not detection; opt-in; outage gives one line and no stall

    @Test func pauseSuppressesDeliveryNotDetection() async throws {
        let s = Scratch()
        _ = runningCodex(s)
        let st = try store(s)
        let snapshot = await passes(codexEngine(s, store: st), from: at("09:10:00"), to: at("09:36:00"))
        var paused = Self.on
        paused.alertsPaused = true
        #expect(items(snapshot, .stalledThread).count == 1)       // detected
        #expect(try await notify(snapshot, st, settings: paused, now: at("09:36:00")).isEmpty)
        #expect(try st.loadNotificationLedger().values.map(\.delivered) == [false])
        // Resuming does not deliver the incident that arose while paused.
        #expect(try await notify(snapshot, st, now: at("09:40:00")).isEmpty)
        // Category off and notifications off (the opt-in default) behave the same.
        var noStalls = Self.on
        noStalls.categories.remove(.stalled)
        #expect(!noStalls.delivers(.stalled) && noStalls.delivers(.waiting))
        #expect(!AppSettings().delivers(.waiting))
        #expect(!AppSettings().categories.contains(.reset))
    }

    @Test func sourceOutageGivesOneErrorLineAndNoStall() async throws {
        let s = Scratch()
        let cwd = runningCodex(s, id: "c-out", originator: "T3 Code")
        let t3 = T3Fixture(s)
        t3.project("p", title: "P", root: cwd)
        t3.thread("T1", project: "p", title: "Outage", created: at("09:00:00"))
        t3.mapping(thread: "T1", driver: "codex", nativeId: "c-out")
        t3.run(thread: "T1", ordinal: 1, status: "running", requested: at("09:00:00"))
        t3.close()
        let access = RecordingAccess()
        access.deny(t3.home)
        let st = try store(s)
        let engine = Engine(collectors: [CodexCollector(codexHome: s.codexHome, store: st)], store: st, home: s.path,
                            t3: T3Collector(reader: T3Reader(t3Home: t3.home, access: access), minInterval: 0))
        let snapshot = await passes(engine, from: at("09:10:00"), to: at("10:30:00"))
        #expect(snapshot.statuses.filter { $0.error != nil }.map(\.source) == [.t3])
        #expect(items(snapshot, .stalledThread).allSatisfy { !$0.threadId.hasPrefix("t3:") })
        #expect(try await notify(snapshot, st, now: at("10:30:00")).allSatisfy { $0.category != .stalled || !$0.incidents.contains { $0.contains("t3:") } })
    }

    // MARK: Usage alerts (§8: 80 % and 95 %, once per window id and reset)

    func reading(_ percent: Double, reset: Date, account: String = "acct-1234") -> ProviderUsage {
        ProviderUsage(provider: .claude, accountId: account, plan: "max",
                      windows: [UsageWindow(id: UsageWindow.sessionId, label: "Session", duration: 5 * 3600, usedPercent: percent, resetsAt: reset)],
                      lastAttemptAt: at("10:00:00"), lastSuccessAt: at("10:00:00"), lastFailure: nil, status: .fresh, source: "test")
    }

    @Test func usageAlertsFireOncePerWindowAndReset() async throws {
        let s = Scratch()
        let st = try store(s)
        let empty = Snapshot(projects: [], statuses: [], checkedAt: at("10:00:00"), indexing: false)
        let reset = at("12:00:00")
        #expect(try await notify(empty, st, now: at("10:00:00"), usage: [reading(70, reset: reset)]).isEmpty)
        #expect(try await notify(empty, st, now: at("10:02:00"), usage: [reading(82, reset: reset)]).map(\.title) == ["Claude session: 18% left"])
        #expect(try await notify(empty, st, now: at("10:04:00"), usage: [reading(85, reset: reset.addingTimeInterval(20))]).isEmpty)
        #expect(try await notify(empty, st, now: at("10:06:00"), usage: [reading(96, reset: reset)]).count == 1)
        #expect(try await notify(empty, st, now: at("10:08:00"), usage: [reading(97, reset: reset)]).isEmpty)
        // A new window (after reset) and an account switch are new identities.
        #expect(try await notify(empty, st, now: at("12:30:00"), usage: [reading(81, reset: at("17:00:00"))]).count == 1)
        #expect(try await notify(empty, st, now: at("12:32:00"), usage: [reading(81, reset: at("17:00:00"), account: "other-9999")]).count == 1)
        // Both thresholds crossed at once: only the higher one is delivered; the lower is recorded.
        #expect(try await notify(empty, st, now: at("12:34:00"), usage: [reading(99, reset: at("22:00:00"))]).map(\.body) == ["5% or less of the session limit left."])
        #expect(try await notify(empty, st, now: at("12:36:00"), usage: [reading(99, reset: at("22:00:00"))]).isEmpty)

        let previous = ["claude|Account ••1234|session": reset]
        let resets = UsageAlerts.resetAlerts(previous: previous, readings: [reading(3, reset: at("17:00:00"))])
        #expect(resets.alerts.map(\.title) == ["Claude session window reset"])
        #expect(UsageAlerts.resetAlerts(previous: resets.current, readings: [reading(4, reset: at("17:00:00"))]).alerts.isEmpty)
    }

    // MARK: Store

    @Test func appSettingsPersist() throws {
        let s = Scratch()
        let url = s.url.appendingPathComponent("app/lighthouse.sqlite")
        var settings = AppSettings()
        settings.notificationsOn = true
        settings.alertsPaused = true
        settings.categories = [.waiting, .reset]
        settings.onboarded = true
        settings.hotkey = .controlOptionSpace
        try Store(url: url).saveAppSettings(settings)
        #expect(try Store(url: url).loadAppSettings() == settings)
        #expect(try Store(url: s.url.appendingPathComponent("b/lighthouse.sqlite")).loadAppSettings() == AppSettings())
    }

    // MARK: Keyboard (SPEC §9): usage rows, project page with a long thread list

    @Test func usageRowsAreKeyboardStopsThatPushTheProviderPage() {
        let p = ProjectSummary(identity: ProjectIdentity(root: "/a", name: "A", kind: .folder), threads: [], status: .recent, lastActivityAt: at("10:00:00"))
        let shelf = ShelfBuilder.build(projects: [p], prefs: ProjectPrefs(), now: at("10:00:00"))
        var nav = ShelfNavigation()
        nav.providers = [.claude, .codex]
        #expect(Array(nav.stops(in: shelf).prefix(3)) == [.provider(.claude), .provider(.codex), .groupHeader(.active)])
        nav.move(1, in: shelf)
        #expect(nav.activate(in: shelf) == .pushProvider(.claude))
        nav.move(1, in: shelf)
        #expect(nav.expand(in: shelf) == .pushProvider(.codex))
        nav.move(2, in: shelf)
        #expect(nav.focusedProject == "/a")
    }

    @Test func projectPageWalksFortyThreadsAndTheEarlierToggle() {
        let now = at("10:00:00")
        let threads = (0..<45).map { i in
            SessionThread(id: "codex:\(i)", owningApp: .codex, providerIdentities: [], cwd: "/a", state: .idle, sourceReadAt: now,
                          lastActivityAt: now.addingTimeInterval(i < 40 ? -Double(i) * 60 : -72 * 3600))
        }
        let project = ProjectSummary(identity: ProjectIdentity(root: "/a", name: "A", kind: .folder), threads: threads, status: .recent, lastActivityAt: now)
        var page = PageNavigation()
        #expect(PageNavigation.stops(project, showEarlier: false, now: now).count == 41)
        for _ in 0..<40 { page.move(1, in: project, now: now) }
        #expect(page.focused == .thread("codex:39"))
        page.move(1, in: project, now: now)
        #expect(page.focused == .earlier)
        page.showEarlier = true
        page.move(5, in: project, now: now)
        #expect(page.focused == .thread("codex:44"))
        page.move(100, in: project, now: now)
        #expect(page.focused == .thread("codex:44"))
        page.move(-200, in: project, now: now)
        #expect(page.focused == .thread("codex:0"))
    }
}
