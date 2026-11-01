import Foundation
import Testing
@testable import LighthouseCore

/// M9 fixes that add an API (`alreadyShown`, `StoreLock`, `Snapshot.t3Outage`). At `fadab14` this
/// file does not compile; the build error is the recorded baseline failure (docs/reliability/test-logs).
extension M4Tests {
    // MARK: F2 a retry after a crash: Notification Center already holds it → marked, not resent

    @Test func m9RetryOfANotificationMacOSAlreadyShowsIsMarkedNotResent() async throws {
        let s = Scratch()
        let st = try store(s)
        let flaky = FlakyLedgerStore(st)
        let t0 = at("10:00:00")
        let id = "waitingForOwner|t3:T1|req-1"
        let input = { (now: Date) in NotificationPlanner.Input(projects: [self.waitingProject(["req-1"], at: t0)], settings: Self.on, now: now) }
        let sent = ScriptedSender(answers: [])
        _ = await NotificationDispatcher(store: flaky, send: { planned in
            _ = await sent.send(planned)
            flaky.failWrites = true   // the process dies after macOS accepted
            return true
        }).evaluate(input(t0))
        // After the retry interval, Notification Center still shows it: no second banner.
        let restarted = NotificationDispatcher(store: try Store(url: st.url), send: sent.send, alreadyShown: { [id] })
        let report = await restarted.evaluate(input(t0.addingTimeInterval(61)))
        #expect(sent.count == 1)
        #expect(report.alreadyShown == [id] && report.submitted.isEmpty)
        #expect(try st.loadNotificationLedger()[id]?.state == .submitted)
        // Later evaluations stay quiet.
        _ = await restarted.evaluate(input(t0.addingTimeInterval(600)))
        #expect(sent.count == 1)
    }

    /// Not in Notification Center (never shown, or the owner cleared it): sent again, once.
    @Test func m9RetryNotHeldByNotificationCenterIsSentOnce() async throws {
        let s = Scratch()
        let st = try store(s)
        let flaky = FlakyLedgerStore(st)
        let t0 = at("10:00:00")
        let input = { (now: Date) in NotificationPlanner.Input(projects: [self.waitingProject(["req-1"], at: t0)], settings: Self.on, now: now) }
        let sent = ScriptedSender(answers: [])
        _ = await NotificationDispatcher(store: flaky, send: { planned in
            _ = await sent.send(planned)
            flaky.failWrites = true
            return true
        }).evaluate(input(t0))
        let restarted = NotificationDispatcher(store: try Store(url: st.url), send: sent.send, alreadyShown: { [] })
        _ = await restarted.evaluate(input(t0.addingTimeInterval(61)))
        _ = await restarted.evaluate(input(t0.addingTimeInterval(300)))
        #expect(sent.count == 2)
        #expect(try st.loadNotificationLedger()["waitingForOwner|t3:T1|req-1"]?.state == .submitted)
    }

    /// A crash inside every submission (a crash loop) stops after `maxAttempts` claims.
    @Test func m9RepeatedCrashesDuringSubmissionAreBounded() async throws {
        let s = Scratch()
        let st = try store(s)
        let t0 = at("10:00:00")
        let input = { (now: Date) in NotificationPlanner.Input(projects: [self.waitingProject(["req-1"], at: t0)], settings: Self.on, now: now) }
        let sent = ScriptedSender(answers: [])
        for run in 0..<6 {
            let flaky = FlakyLedgerStore(try Store(url: st.url))
            _ = await NotificationDispatcher(store: flaky, send: { planned in
                _ = await sent.send(planned)
                flaky.failWrites = true
                return true
            }, alreadyShown: { [] }).evaluate(input(t0.addingTimeInterval(Double(run) * 120)))
        }
        #expect(sent.count == NotificationDispatcher.maxAttempts)
    }

    // MARK: F3 one writer per store (owner scenario 4)

    @Test func m9StoreLockAdmitsOneHolderAndFreesOnRelease() throws {
        let s = Scratch()
        let url = s.url.appendingPathComponent("app/lighthouse.sqlite")
        var first: StoreLock? = try #require(StoreLock(store: url))
        #expect(StoreLock(store: url) == nil)
        // Another process cannot take it either (flock is per open file, across processes).
        #expect(try otherProcessTakesLock(url.deletingLastPathComponent().path) == false)
        _ = first
        first = nil
        #expect(try otherProcessTakesLock(url.deletingLastPathComponent().path) == true)
        #expect(StoreLock(store: url) != nil)
        // A different store folder is independent (a scratch test store beside the user's).
        let other = s.url.appendingPathComponent("other/lighthouse.sqlite")
        let held = StoreLock(store: url)
        #expect(held != nil && StoreLock(store: other) != nil)
    }

    /// Tries `flock(LOCK_EX | LOCK_NB)` on `directory` from a separate process.
    func otherProcessTakesLock(_ directory: String) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", "-c", "import fcntl,os,sys\nfd=os.open(sys.argv[1],os.O_RDONLY)\ntry:\n fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)\nexcept OSError:\n sys.exit(1)", directory]
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    // MARK: F4 T3 outage after a good read: one alert, same identity across restart (owner scenario 2)

    func outageFixture(_ s: Scratch) -> (T3Fixture, RecordingAccess) {
        let cwd = runningCodex(s, id: "c-out", originator: "T3 Code")
        let t3 = T3Fixture(s)
        t3.project("p", title: "P", root: cwd)
        t3.thread("T1", project: "p", title: "Outage", created: at("09:00:00"))
        t3.mapping(thread: "T1", driver: "codex", nativeId: "c-out")
        t3.run(thread: "T1", ordinal: 1, status: "running", requested: at("09:00:00"))
        t3.close()
        return (t3, RecordingAccess())
    }

    func outageEngine(_ s: Scratch, _ t3: T3Fixture, _ access: RecordingAccess, _ st: Store) -> Engine {
        Engine(collectors: [CodexCollector(codexHome: s.codexHome, store: st)], store: st, home: s.path,
               t3: T3Collector(reader: T3Reader(t3Home: t3.home, access: access), minInterval: 0))
    }

    func deliver(_ snapshot: Snapshot, _ st: Store, now: Date, sent: ScriptedSender) async {
        let alerts = snapshot.t3Outage?.alert(now: now).map { [$0] } ?? []
        _ = await NotificationDispatcher(store: st, send: sent.send)
            .evaluate(.init(projects: snapshot.projects, usageAlerts: alerts, settings: Self.on, now: now))
    }

    @Test func m9T3OutageAfterAGoodReadAlertsOnceAcrossRestart() async throws {
        let s = Scratch()
        let (t3, access) = outageFixture(s)
        let url = s.url.appendingPathComponent("app/lighthouse.sqlite")
        let sent = ScriptedSender(answers: [])
        do {
            let st = try Store(url: url)
            let engine = outageEngine(s, t3, access, st)
            var snapshot = await engine.pass(now: at("09:10:00"))
            #expect(snapshot.t3Outage == nil)
            access.deny(t3.home)   // T3 becomes unreadable (a schema change, a broken sidecar)
            snapshot = await passes(engine, from: at("09:12:00"), to: at("09:20:00"))
            #expect(snapshot.t3Outage?.alert(now: at("09:20:00")) == nil)
            #expect(snapshot.statuses.first { $0.source == .t3 }?.lastReadAt == at("09:10:00"))
            for minute in stride(from: 24, through: 40, by: 4) {
                let now = at("09:\(minute):00")
                snapshot = await engine.pass(now: now)
                await deliver(snapshot, st, now: now, sent: sent)
            }
            #expect(sent.submitted == ["source|t3|\(Int(at("09:10:00").timeIntervalSince1970))"])
        }
        // Restart while T3 is still unreadable: the same outage, no second alert.
        let st = try Store(url: url)
        let engine = outageEngine(s, t3, access, st)
        var snapshot = await passes(engine, from: at("09:50:00"), to: at("10:10:00"))
        #expect(snapshot.t3Outage?.id == "source|t3|\(Int(at("09:10:00").timeIntervalSince1970))")
        await deliver(snapshot, st, now: at("10:10:00"), sent: sent)
        // (After the restart T3 is unread, so the Codex session stands alone and may stall on its own evidence.)
        #expect(sent.submitted.filter { $0.hasPrefix("source|") }.count == 1)
        // Recovery clears it; a later outage is a new identity and alerts once more.
        access.allowAll()
        snapshot = await engine.pass(now: at("10:14:00"))
        #expect(snapshot.t3Outage == nil)
        access.deny(t3.home)
        snapshot = await passes(engine, from: at("10:18:00"), to: at("10:30:00"))
        await deliver(snapshot, st, now: at("10:30:00"), sent: sent)
        #expect(sent.submitted.filter { $0.hasPrefix("source|") } == ["source|t3|\(Int(at("09:10:00").timeIntervalSince1970))",
                                                                       "source|t3|\(Int(at("10:14:00").timeIntervalSince1970))"])
    }

    /// No alert when T3 was never read here (not installed, or unreadable from the first launch on).
    @Test func m9T3NeverReadOrMissingRaisesNoOutage() async throws {
        let s = Scratch()
        let (t3, access) = outageFixture(s)
        access.deny(t3.home)
        let st = try store(s)
        let snapshot = await passes(outageEngine(s, t3, access, st), from: at("09:10:00"), to: at("10:30:00"))
        #expect(snapshot.t3Outage == nil)
        let missing = Scratch()
        _ = runningCodex(missing)
        let none = Engine(collectors: [CodexCollector(codexHome: missing.codexHome)], store: nil, home: missing.path,
                          t3: T3Collector(reader: T3Reader(t3Home: missing.dir("t3-absent")), minInterval: 0))
        #expect(await passes(none, from: at("09:10:00"), to: at("10:30:00")).t3Outage == nil)
    }

    /// Pause, notifications off or the category off suppress the outage alert like any other.
    @Test func m9OutageAlertFollowsTheOwnersSwitches() throws {
        let outage = SourceOutage(source: .t3, lastSuccess: at("09:10:00"), failingSince: at("09:12:00"))
        #expect(outage.alert(now: at("09:21:59")) == nil)
        let alert = try #require(outage.alert(now: at("09:22:00")))
        #expect(alert.category == .source && alert.provider == nil)
        #expect(!alert.title.contains("unavailable:") && !alert.body.contains("schema"))
        var off = Self.on
        off.categories.remove(.source)
        let plan = NotificationPlanner.plan(.init(projects: [], usageAlerts: [alert], settings: off, now: at("09:22:00")), ledger: [:])
        #expect(plan.deliver.isEmpty && plan.record.map(\.state) == [.suppressed])
        #expect(AppSettings().categories.contains(.source))
    }

    // MARK: F1 busy read: newest run only, tool calls only, no text

    /// The busy query keeps to in-flight tool calls of the thread's newest run: a call T3 left
    /// `running` on an older run, and a delegated `subagent` item, do not make a thread busy.
    @Test func m9StaleOrSubagentItemsDoNotMakeAThreadBusy() async throws {
        let s = Scratch()
        let cwd = runningCodex(s, id: "c-old", originator: "T3 Code")
        let t3 = T3Fixture(s)
        t3.project("p", title: "P", root: cwd)
        t3.thread("T1", project: "p", title: "Old leftovers", created: at("08:00:00"))
        t3.mapping(thread: "T1", driver: "codex", nativeId: "c-old")
        t3.run(thread: "T1", ordinal: 1, status: "completed", requested: at("08:00:00"), completed: at("08:30:00"))
        t3.run(thread: "T1", ordinal: 2, status: "running", requested: at("09:00:00"))
        addTurnItems(t3)
        turnItem(t3, "left-over", thread: "T1", run: "run-T1-1", started: at("08:10:00"))
        turnItem(t3, "delegate", thread: "T1", run: "run-T1-2", type: "subagent", started: at("09:06:00"))
        let state = try T3Reader(t3Home: t3.home).read().get()
        #expect(state.busySince.isEmpty)
        let engine = Engine(collectors: [CodexCollector(codexHome: s.codexHome)], store: nil, home: s.path,
                            t3: T3Collector(reader: T3Reader(t3Home: t3.home), minInterval: 0))
        let snapshot = await passes(engine, from: at("09:10:00"), to: at("09:40:00"))
        #expect(items(snapshot, .stalledThread).count == 1)
    }

    /// The busy read selects no text: the command canary in the item payload never reaches the store.
    @Test func m9BusyReadKeepsCommandTextOutOfTheStore() async throws {
        let s = Scratch()
        let st = try store(s)
        let (t3, engine) = busyT3(s, store: st)
        let snapshot = await passes(engine, from: at("09:10:00"), to: at("09:40:00"))
        #expect(snapshot.projects.first?.threads.first?.busySince == at("09:06:00"))
        st.checkpointWAL()
        for suffix in ["", "-wal"] {
            #expect(!bytesContain(st.url.path + suffix, Fixture.bodyCanary))
        }
        _ = t3
    }
}

// MARK: M9-E01 (Sol review of 21e48dd): a held notification covers only the incidents it was sent for

extension M4Tests {
    func waitingItems(_ requests: [(String, Date)], root: String = "/p") -> ProjectSummary {
        ProjectSummary(identity: ProjectIdentity(root: root, name: "P", kind: .folder), threads: [], status: .needsYou,
                       lastActivityAt: requests.map(\.1).max(),
                       attentionItems: requests.map { request, entered in
                           AttentionItem(id: "waitingForOwner|t3:T1|\(request)", kind: .waitingForOwner, threadId: "t3:T1", enteredAt: entered,
                                         label: "Approval requested · Asks")
                       })
    }

    /// A is accepted by macOS, then the app dies before marking it. Before A's retry, B opens in the
    /// same project. Notification Center still holds A: A is reconciled, not resent; B, which A's
    /// notification never covered, is delivered once (after the 5 min coalescing window).
    @Test func m9HeldNotificationCoversOnlyItsOwnIncidents() async throws {
        let s = Scratch()
        let st = try store(s)
        let flaky = FlakyLedgerStore(st)
        let t0 = at("10:00:00")
        let a = "waitingForOwner|t3:T1|req-A", b = "waitingForOwner|t3:T1|req-B"
        let sent = ScriptedSender(answers: [])
        _ = await NotificationDispatcher(store: flaky, send: { planned in
            _ = await sent.send(planned)
            flaky.failWrites = true   // the process dies after macOS accepted A
            return true
        }).evaluate(.init(projects: [waitingItems([("req-A", t0)])], settings: Self.on, now: t0))
        #expect(sent.submitted == [a])
        let both = [waitingItems([("req-A", t0), ("req-B", t0.addingTimeInterval(30))])]
        let restarted = NotificationDispatcher(store: try Store(url: st.url), send: sent.send, alreadyShown: { [a] })
        for seconds in [61.0, 120, 240, 301, 400, 900] {
            _ = await restarted.evaluate(.init(projects: both, settings: Self.on, now: t0.addingTimeInterval(seconds)))
        }
        #expect(sent.submitted == [a, b])
        let ledger = try st.loadNotificationLedger()
        #expect(ledger[a]?.state == .submitted && ledger[b]?.state == .submitted)
    }
}
