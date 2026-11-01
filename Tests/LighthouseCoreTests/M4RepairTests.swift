import Foundation
import Testing
@testable import LighthouseCore

/// Records what a sender was asked to submit and answers from a script (rejections first).
final class ScriptedSender: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [Bool]
    private(set) var submitted: [String] = []

    init(answers: [Bool]) { self.answers = answers }

    var send: NotificationDispatcher.Send {
        { [self] planned in answer(planned.id) }
    }

    private func answer(_ id: String) -> Bool {
        lock.withLock {
            submitted.append(id)
            return answers.isEmpty ? true : answers.removeFirst()
        }
    }

    var count: Int { lock.withLock { submitted.count } }
}

/// The real store, with writes that fail on demand (M4-R03).
final class FlakyLedgerStore: NotificationLedgerStore, @unchecked Sendable {
    let store: Store
    var failWrites = false
    init(_ store: Store) { self.store = store }

    func loadNotificationLedger() throws -> [String: NotificationRecord] { try store.loadNotificationLedger() }

    func writeNotificationRecords(_ records: [NotificationRecord], now: Date, keepingOpen: Set<String>) throws {
        if failWrites { throw StoreError.sql("injected write failure") }
        try store.writeNotificationRecords(records, now: now, keepingOpen: keepingOpen)
    }
}

/// M4 repair round 1 (review of `a2bbd8a`): one regression test per confirmed item.
extension M4Tests {
    func waitingProject(_ requests: [String], root: String = "/p", at time: Date) -> ProjectSummary {
        ProjectSummary(identity: ProjectIdentity(root: root, name: "P", kind: .folder), threads: [], status: .needsYou, lastActivityAt: time,
                       attentionItems: requests.map {
                           AttentionItem(id: "waitingForOwner|t3:T1|\($0)", kind: .waitingForOwner, threadId: "t3:T1", enteredAt: time,
                                         label: "Approval requested · Asks")
                       })
    }

    // MARK: M4-R01 provider page keyboard

    @Test func providerPageKeyboardOpensAProjectAndBackReturns() {
        var routes = PanelRoutes()
        routes.route = .provider(.codex)
        let roots = ["/a", "/b"]
        routes.moveProviderFocus(1, count: roots.count)
        #expect(routes.providerFocus == 0)
        routes.moveProviderFocus(1, count: roots.count)
        #expect(routes.providerFocus == 1)
        routes.moveProviderFocus(1, count: roots.count)
        #expect(routes.providerFocus == 1)
        let opened = routes.activateProviderFocus(roots: roots)
        #expect(opened)
        #expect(routes.route == .project("/b"))
        #expect(routes.projectReturn == .provider(.codex))
        routes.pop()
        #expect(routes.route == .provider(.codex))
        #expect(routes.providerFocus == 1)
        routes.pop()
        #expect(routes.route == .home)
        // A provider page reached from home again starts unfocused.
        routes.route = .provider(.codex)
        #expect(routes.providerFocus == nil)
        let openedUnfocused = routes.activateProviderFocus(roots: roots)
        #expect(!openedUnfocused)
        #expect(routes.route == .provider(.codex))
    }

    // MARK: M4-R02 rejected submission: pending, bounded retry, submitted only on acceptance

    @Test func rejectedNotificationIsRetriedThenDeliveredOnceAcrossRestart() async throws {
        let s = Scratch()
        let st = try store(s)
        let t0 = at("10:00:00")
        let input = { (now: Date) in NotificationPlanner.Input(projects: [self.waitingProject(["req-1"], at: t0)], settings: Self.on, now: now) }
        let sender = ScriptedSender(answers: [false, true])
        let dispatcher = NotificationDispatcher(store: st, send: sender.send)

        var report = await dispatcher.evaluate(input(t0))
        #expect(report.rejected.count == 1 && report.submitted.isEmpty)
        var record = try #require(try st.loadNotificationLedger()["waitingForOwner|t3:T1|req-1"])
        #expect(record.state == .pending && record.attempts == 1)
        // Inside the retry interval nothing is sent.
        report = await dispatcher.evaluate(input(t0.addingTimeInterval(30)))
        #expect(sender.count == 1)
        // After it, the retry is accepted and marked submitted.
        report = await dispatcher.evaluate(input(t0.addingTimeInterval(61)))
        #expect(report.submitted.map(\.id) == ["waitingForOwner|t3:T1|req-1"])
        record = try #require(try st.loadNotificationLedger()["waitingForOwner|t3:T1|req-1"])
        #expect(record.state == .submitted && record.attempts == 2)
        // Restart: no duplicate.
        let restarted = NotificationDispatcher(store: try Store(url: st.url), send: sender.send)
        report = await restarted.evaluate(input(t0.addingTimeInterval(600)))
        #expect(report.submitted.isEmpty && sender.count == 2)

        // Bounded: a notification macOS always rejects is tried maxAttempts times, then never again.
        let s2 = Scratch()
        let never = ScriptedSender(answers: Array(repeating: false, count: 10))
        let d2 = NotificationDispatcher(store: try store(s2), send: never.send)
        for minute in 0..<10 { _ = await d2.evaluate(input(t0.addingTimeInterval(Double(minute) * 120))) }
        #expect(never.count == NotificationDispatcher.maxAttempts)
        #expect(try store(s2).loadNotificationLedger()["waitingForOwner|t3:T1|req-1"]?.state == .failed)
    }

    /// A pending record left by a crash between the durable write and the submission is sent after restart.
    @Test func pendingRecordFromAnInterruptedRunIsSentAfterRestart() async throws {
        let s = Scratch()
        let st = try store(s)
        let t0 = at("10:00:00")
        try st.writeNotificationRecords([NotificationRecord(incident: "waitingForOwner|t3:T1|req-1", projectRoot: "/p", at: t0, state: .pending)],
                                        now: t0, keepingOpen: [])
        let sender = ScriptedSender(answers: [])
        let report = await NotificationDispatcher(store: st, send: sender.send)
            .evaluate(.init(projects: [waitingProject(["req-1"], at: t0)], settings: Self.on, now: t0.addingTimeInterval(5)))
        #expect(report.submitted.count == 1)
        #expect(try st.loadNotificationLedger()["waitingForOwner|t3:T1|req-1"]?.state == .submitted)
    }

    // MARK: M4-R03 ledger write failure: nothing sent until the decision is durable

    @Test func ledgerWriteFailureSendsNothingThenDeliversOnceAcrossRestart() async throws {
        let s = Scratch()
        let flaky = FlakyLedgerStore(try store(s))
        let sender = ScriptedSender(answers: [])
        let t0 = at("10:00:00")
        let input = { (now: Date) in NotificationPlanner.Input(projects: [self.waitingProject(["req-1"], at: t0)], settings: Self.on, now: now) }
        let dispatcher = NotificationDispatcher(store: flaky, send: sender.send)
        flaky.failWrites = true
        var report = await dispatcher.evaluate(input(t0))
        #expect(report.ledgerUnavailable && sender.count == 0)
        #expect(await dispatcher.ledger.isEmpty)
        flaky.failWrites = false
        report = await dispatcher.evaluate(input(t0.addingTimeInterval(60)))
        #expect(report.submitted.count == 1 && sender.count == 1)
        let restarted = NotificationDispatcher(store: try store(s), send: sender.send)
        report = await restarted.evaluate(input(t0.addingTimeInterval(120)))
        #expect(report.submitted.isEmpty && sender.count == 1)
    }

    // MARK: M4-R04 retention never drops an open incident

    @Test func openIncidentKeepsItsRecordPastRetention() async throws {
        let s = Scratch()
        let st = try store(s)
        let t0 = at("10:00:00")
        let sender = ScriptedSender(answers: [])
        let later = t0.addingTimeInterval(Store.notificationRetention + 24 * 3600)
        // Day 0: req-1 is delivered; a closed incident is recorded too.
        _ = await NotificationDispatcher(store: st, send: sender.send)
            .evaluate(.init(projects: [waitingProject(["req-1", "req-closed"], at: t0)], settings: Self.on, now: t0))
        #expect(sender.count == 1)
        // Day 31: req-1 is still pending; another project's incident causes a write (and pruning).
        let other = waitingProject(["req-x"], root: "/q", at: later)
        _ = await NotificationDispatcher(store: st, send: sender.send)
            .evaluate(.init(projects: [waitingProject(["req-1"], at: t0), other], settings: Self.on, now: later))
        let ledger = try st.loadNotificationLedger()
        #expect(ledger["waitingForOwner|t3:T1|req-1"]?.state == .submitted)
        #expect(ledger["waitingForOwner|t3:T1|req-closed"] == nil)
        // Restart: req-1 is not notified again.
        let restarted = NotificationDispatcher(store: try Store(url: st.url), send: sender.send)
        let report = await restarted.evaluate(.init(projects: [waitingProject(["req-1"], at: t0), other], settings: Self.on,
                                                    now: later.addingTimeInterval(600)))
        #expect(report.submitted.isEmpty)
        #expect(sender.count == 2)
    }

    // MARK: M4-R05 mapped provider session unreadable while T3 stays readable

    @Test func mappedRolloutOutageRaisesNoStallAndRestartsTheClock() async throws {
        let s = Scratch()
        let cwd = runningCodex(s, id: "c-map", originator: "T3 Code")
        let t3 = T3Fixture(s)
        t3.project("p", title: "P", root: cwd)
        t3.thread("T1", project: "p", title: "Mapped", created: at("09:00:00"))
        t3.mapping(thread: "T1", driver: "codex", nativeId: "c-map")
        t3.run(thread: "T1", ordinal: 1, status: "running", requested: at("09:00:00"))
        t3.close()
        let access = RecordingAccess()
        let st = try store(s)
        let engine = Engine(collectors: [CodexCollector(codexHome: s.codexHome, access: access, store: st)], store: st, home: s.path,
                            t3: T3Collector(reader: T3Reader(t3Home: t3.home), minInterval: 0))
        _ = await passes(engine, from: at("09:08:00"), to: at("09:12:00"))
        access.deny(s.url.appendingPathComponent(Self.rollout("c-map")).path)
        var sent: [PlannedNotification] = []
        var t = at("09:14:00")
        var snapshot = await engine.pass(now: t)
        while t < at("10:02:00") {
            t = t.addingTimeInterval(240)
            snapshot = await engine.pass(now: t)
            #expect(items(snapshot, .stalledThread).isEmpty, "stall during outage at \(t)")
            sent += try await notify(snapshot, st, now: t)
        }
        let thread = try #require(snapshot.projects.flatMap(\.threads).first { $0.t3ThreadId == "T1" })
        #expect(thread.state == .running)
        #expect(!thread.progressCoverage)
        #expect(AttentionRules.stallNote(for: thread) == "Coverage unknown")
        #expect(sent.isEmpty)
        // Recovery at 10:06: 61 min since the last progress, but a fresh interval starts now.
        access.allowAll()
        snapshot = await passes(engine, from: at("10:06:00"), to: at("10:34:00"))
        #expect(items(snapshot, .stalledThread).isEmpty)
        snapshot = await engine.pass(now: at("10:37:00"))
        #expect(items(snapshot, .stalledThread).count == 1)
    }

    // MARK: M4-R06 child activity without progress does not hide a stalled parent

    @Test func childRepeatingItsTotalDoesNotHideAStalledParent() async throws {
        let s = Scratch()
        let cwd = runningCodex(s, id: "c-parent")
        // A spawned child: real progress once at 09:06, then the same total every 4 min.
        var child = #"{"timestamp":"2026-10-29T09:06:00.000Z","type":"session_meta","payload":{"id":"c-child","cwd":"\#(cwd)","source":{"subagent":{"thread_spawn":{"parent_thread_id":"c-parent","agent_nickname":"coder"}}}}}"# + "\n"
        child += Self.event("task_started", "09:06:00") + Self.tokens(50, "09:06:30")
        var t = at("09:10:00")
        while t <= at("10:30:00") {
            child += Self.tokens(50, Self.clock(t))
            t = t.addingTimeInterval(240)
        }
        s.write("codex/sessions/2026/10/29/rollout-2026-10-29T09-06-00-c-child.jsonl", child)
        let engine = codexEngine(s)
        var snapshot = await passes(engine, from: at("09:10:00"), to: at("09:34:00"))
        let parent = try #require(snapshot.projects.first?.threads.first)
        #expect(parent.subagents.map(\.id) == ["c-child"])
        #expect(parent.subagents.first?.state == .running)
        #expect(snapshot.projects.flatMap(\.attentionItems).isEmpty)
        snapshot = await passes(engine, from: at("09:38:00"), to: at("10:30:00"))
        // One item for the 30+ min without progress (the child stays active, so it is not "silent").
        #expect(items(snapshot, .silentSubagent).isEmpty)
        #expect(items(snapshot, .stalledThread).map(\.id) == ["stalledThread|codex:c-parent|\(Int(at("09:36:30").timeIntervalSince1970))"])
    }

    // MARK: Owner change: default hotkey ⌃⌥Space (ChatGPT owns ⌥Space)

    @Test func defaultHotkeyIsControlOptionSpaceAndAChosenOptionSpaceIsKept() throws {
        #expect(AppSettings().hotkey == .controlOptionSpace)
        let s = Scratch()
        let st = try store(s)
        #expect(try st.loadAppSettings().hotkey == .controlOptionSpace)
        var chosen = AppSettings()
        chosen.hotkey = .optionSpace
        try st.saveAppSettings(chosen)
        #expect(try Store(url: st.url).loadAppSettings().hotkey == .optionSpace)
    }

    // MARK: M4-R07 scratch T3 source for the live replacement-request check

    @Test func scratchT3HomeIsOnlyHonouredInTestModeAndNeverTheRealOne() {
        let realStore = URL(fileURLWithPath: "/Users/me/Library/Application Support/Lighthouse/lighthouse.sqlite")
        let test = ["app", TestHooks.storeFlag, "/private/tmp/s/store/l.sqlite", TestHooks.claudeFlag, "/private/tmp/s/claude",
                    TestHooks.codexFlag, "/private/tmp/s/codex"]
        #expect(TestHooks.scratchT3Home(arguments: test + [TestHooks.t3Flag, "/private/tmp/s/t3"], realT3Home: "/Users/me/.t3",
                                        realStore: realStore) == "/private/tmp/s/t3")
        #expect(TestHooks.scratchT3Home(arguments: test, realT3Home: "/Users/me/.t3", realStore: realStore) == nil)
        // Returned as given, never rewritten to the /tmp symlink (that path would read as "database not found").
        let s = Scratch()
        let t3 = s.dir("t3")
        #expect(TestHooks.scratchT3Home(arguments: test + [TestHooks.t3Flag, t3], realT3Home: "/Users/me/.t3", realStore: realStore) == t3)
        #expect(TestHooks.scratchT3Home(arguments: test + [TestHooks.t3Flag, "/private/tmp/x/t3"], realT3Home: "/Users/me/.t3",
                                        realStore: realStore) == "/private/tmp/x/t3")
        #expect(TestHooks.scratchT3Home(arguments: ["app", TestHooks.t3Flag, "/private/tmp/s/t3"], realT3Home: "/Users/me/.t3",
                                        realStore: realStore) == nil)
        for real in ["/Users/me/.t3", "/Users/me/.t3/userdata", "/Users/me/.t3/../.t3"] {
            #expect(TestHooks.scratchT3Home(arguments: test + [TestHooks.t3Flag, real], realT3Home: "/Users/me/.t3", realStore: realStore) == nil)
        }
        #expect(TestHooks.scratchT3Home(arguments: test + [TestHooks.t3Flag, "relative/t3"], realT3Home: "/Users/me/.t3", realStore: realStore) == nil)
    }

    // MARK: M4-R08 T3 titles and delegated-task nesting (fixture mirrors T3's schema rows)

    static let parentId = "aaaaaaaa-0000-4000-8000-000000000001"
    static func delegated(_ name: String) -> String {
        "thread:delegated-task:command%3Amcp%3Aaaaaaaaa-0000-4000-8000-000000000002%3Adelegate-task%3A\(name)"
    }

    /// Parent T3 thread with two delegated tasks: lineage `subagent` + `parentThreadId`, `node:` subagent
    /// rows, Codex mappings, and the Codex rollouts T3 wrote (`originator: T3 Code`, `source: vscode`,
    /// no parent link in the JSONL), matching the rows T3 writes.
    func delegatedTaskFixture(_ s: Scratch) -> (T3Fixture, String) {
        let cwd = s.dir("Projects/recipe-box")
        let kids = [("search-review-01", "review: search ranking", "019a0000-0000-7000-8000-0000000000a1"),
                    ("search-survey", "survey: search behavior", "019a0000-0000-7000-8000-0000000000a2")]
        for (_, _, native) in kids {
            s.write(Self.rollout(native),
                    #"{"timestamp":"2026-10-29T09:44:52.000Z","type":"session_meta","payload":{"id":"\#(native)","cwd":"\#(cwd)","originator":"T3 Code","source":"vscode"}}"# + "\n"
                    + Self.event("task_started", "09:44:53") + Self.tokens(300, "09:46:00") + Self.event("task_complete", "09:47:00"))
        }
        let t3 = T3Fixture(s)
        t3.project("aaaaaaaa-0000-4000-8000-000000000003", title: "Recipe Box", root: cwd)
        t3.thread(Self.parentId, project: "aaaaaaaa-0000-4000-8000-000000000003", title: "Plan the recipe search page", created: at("09:00:00"))
        t3.run(thread: Self.parentId, ordinal: 1, status: "completed", requested: at("09:40:00"), completed: at("09:50:00"))
        for (name, title, native) in kids {
            let id = Self.delegated(name)
            t3.thread(id, project: "aaaaaaaa-0000-4000-8000-000000000003", title: title, created: at("09:44:00"), parent: Self.parentId)
            t3.mapping(thread: id, driver: "codex", nativeId: native)
            t3.run(thread: id, ordinal: 1, status: "completed", requested: at("09:44:52"), completed: at("09:47:00"))
            t3.subagent("node:delegated-task:command%3Amcp%3Aaaaaaaaa-0000-4000-8000-000000000002%3Adelegate-task%3A\(name)",
                        parent: Self.parentId, child: id, provider: "codex", status: "completed", started: at("09:44:52"),
                        updated: at("09:47:00"), completed: at("09:47:00"))
        }
        t3.close()
        return (t3, cwd)
    }

    @Test func realSchemaDelegatedTasksTakeT3TitlesAndNestUnderTheirParent() async throws {
        let s = Scratch()
        let (t3, _) = delegatedTaskFixture(s)
        let snapshot = await Engine(collectors: [CodexCollector(codexHome: s.codexHome)], store: nil, home: s.path,
                                    t3: T3Collector(reader: T3Reader(t3Home: t3.home), minInterval: 0)).pass(now: at("10:00:00"))
        let project = try #require(snapshot.projects.first)
        #expect(project.threads.count == 1)
        let parent = try #require(project.threads.first)
        #expect(parent.id == "t3:\(Self.parentId)")
        #expect(parent.displayTitle == "Plan the recipe search page")
        #expect(Set(parent.subagents.map(\.name)) == ["review: search ranking", "survey: search behavior"])
        #expect(Set(parent.subagents.compactMap(\.t3ThreadId)) == [Self.delegated("search-review-01"), Self.delegated("search-survey")])
        #expect(!snapshot.projects.flatMap(\.threads).contains { $0.displayTitle.hasPrefix("Codex session ·") })
        #expect(project.mostRecentThread?.displayTitle == "Plan the recipe search page")
    }

    /// Scratch test mode with JSONL roots and no T3 source.
    /// The T3-owned sessions can only show their fallback titles unnested; the T3 status line says why.
    @Test func runWithoutT3SourceSaysSoInTheT3StatusLine() async throws {
        let s = Scratch()
        _ = delegatedTaskFixture(s)
        let snapshot = await Engine(collectors: [CodexCollector(codexHome: s.codexHome)], store: nil, home: s.path,
                                    t3NotRead: "Not read in test mode").pass(now: at("10:00:00"))
        let rows = snapshot.projects.flatMap(\.threads)
        #expect(rows.count == 2 && rows.allSatisfy { $0.owningApp == .t3 && $0.displayTitle.hasPrefix("Codex session ·") })
        #expect(snapshot.statuses.first { $0.source == .t3 }?.error == "Not read in test mode")
        // With a T3 source the note is never shown.
        let (t3, _) = (T3Fixture(Scratch()), 0)
        let withT3 = await Engine(collectors: [], store: nil, home: s.path, t3: T3Collector(reader: T3Reader(t3Home: t3.home), minInterval: 0),
                                  t3NotRead: "Not read in test mode").pass(now: at("10:00:00"))
        #expect(withT3.statuses.first { $0.source == .t3 }?.error != "Not read in test mode")
    }

    // MARK: M4-R09 panel height follows the page, top edge fixed

    @Test func panelFrameFollowsContentAndKeepsItsTopEdge() throws {
        // A tall frame around a short project page (fictional sizes).
        let tall = CGRect(x: 500, y: 100, width: 400, height: 600)
        let short = try #require(PanelFrame.fitted(tall, contentHeight: 250.4, maxHeight: 600))
        #expect(short == CGRect(x: 500, y: 449, width: 400, height: 251))
        #expect(short.maxY == tall.maxY)
        // Content past the maximum is capped (the page scrolls); the top edge stays.
        let long = try #require(PanelFrame.fitted(short, contentHeight: 1500, maxHeight: 600))
        #expect(long.height == 600 && long.maxY == tall.maxY)
        // Back to a mid-height page, same top edge.
        let home = try #require(PanelFrame.fitted(long, contentHeight: 380, maxHeight: 600))
        #expect(home.height == 380 && home.maxY == tall.maxY)
        // A fitting frame is left alone; no content measured yet is ignored.
        #expect(PanelFrame.fitted(home, contentHeight: 379.7, maxHeight: 600) == nil)
        #expect(PanelFrame.fitted(home, contentHeight: 0, maxHeight: 600) == nil)
    }

    @Test func scrollAreaCapKeepsThePageWithinTheMaximum() {
        // Home with search open: a page taller than the maximum (fictional sizes).
        let cap = PanelFrame.scrollCap(maxHeight: 720, contentHeight: 760, scrollHeight: 500)
        #expect(cap == 460)
        #expect(760 - 500 + cap == 720)
        // A short page is not capped below its content; the cap never drops under the minimum.
        #expect(PanelFrame.scrollCap(maxHeight: 720, contentHeight: 300, scrollHeight: 100) == 520)
        #expect(PanelFrame.scrollCap(maxHeight: 400, contentHeight: 700, scrollHeight: 50) == 120)
        // Not measured yet: the earlier fixed cap.
        #expect(PanelFrame.scrollCap(maxHeight: 720, contentHeight: 0, scrollHeight: 0) == 560)
    }
}
