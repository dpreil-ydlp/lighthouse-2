import Foundation
import Testing
@testable import LighthouseCore

/// SPEC §11 M3: read-only T3 reader, aliases (§5.2), T3 routing, waiting/silent attention (§5.4).
@Suite struct T3Tests {
    let now = Fixture.date("2026-10-29T10:10:00.000Z")
    func at(_ time: String) -> Date { Fixture.date("2026-10-29T\(time).000Z") }

    func engine(_ s: Scratch, _ t3: T3Fixture, access: SourceAccess = ReadOnlyFileSystem(), store: Store? = nil,
                clock: (@Sendable () -> Double)? = nil) -> Engine {
        let reader = clock.map { T3Reader(t3Home: t3.home, access: access, clock: $0) } ?? T3Reader(t3Home: t3.home, access: access)
        return Engine(collectors: [ClaudeCodeCollector(root: s.claudeRoot, store: store), CodexCollector(codexHome: s.codexHome, store: store)],
                      store: store, home: s.path, t3: T3Collector(reader: reader))
    }

    /// T3 maps the Codex fixture parent (001) and its spawned child (002); JSONL exposes both too.
    func codexAliasFixture(_ s: Scratch) -> (T3Fixture, String) {
        s.installFixtures()
        // A genuine token increase in the child, so its single contribution is visible.
        s.append("codex/sessions/2026/10/29/rollout-2026-10-29T10-01-00-\(Fixture.codexChild).jsonl",
                 #"{"timestamp":"2026-10-29T10:01:05.000Z","ordinal":2,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":200}}}}"# + "\n")
        let t3 = T3Fixture(s)
        let root = s.dir("Projects/recipes")
        t3.project("p1", title: "Recipes", root: root)
        t3.thread("T-parent", project: "p1", title: "Recipe card layout", created: at("10:00:00"))
        t3.thread("T-child", project: "p1", title: "coder", created: at("10:01:00"), parent: "T-parent")
        t3.mapping(thread: "T-parent", driver: "codex", nativeId: Fixture.codexParent)
        t3.mapping(thread: "T-child", driver: "codex", nativeId: Fixture.codexChild)
        t3.run(thread: "T-parent", ordinal: 1, status: "completed", requested: at("10:00:00"), completed: at("10:00:09"))
        t3.subagent("sa-1", parent: "T-parent", child: "T-child", provider: "codex", status: "running", started: at("10:01:00"), updated: at("10:01:05"))
        t3.close()
        return (t3, ProjectResolver.standardize(root))
    }

    // MARK: Acceptance (1): same parent and child in T3 and JSONL

    @Test func sameParentAndChildMergeIntoOneRowOneChildOneTokenContribution() async throws {
        let s = Scratch()
        let (t3, root) = codexAliasFixture(s)
        let snapshot = await engine(s, t3).pass(now: now)
        let threads = snapshot.projects.flatMap(\.threads)

        // One parent row, owned by T3, carrying the JSONL session as its alias.
        let parentIdentity = ProviderIdentity(provider: .codex, nativeId: Fixture.codexParent)
        #expect(threads.filter { $0.providerIdentities.contains(parentIdentity) }.count == 1)
        let parent = try #require(threads.first { $0.id == "t3:T-parent" })
        #expect(parent.owningApp == .t3)
        #expect(parent.aliasIds == ["codex:\(Fixture.codexParent)"])
        #expect(parent.displayTitle == "Recipe card layout")
        #expect(!threads.contains { $0.id == "codex:\(Fixture.codexParent)" || $0.sessionId == Fixture.codexChild })

        // One child: the T3 child, merged with the JSONL spawned session; never a parent, never twice.
        #expect(parent.subagents.map(\.id) == ["t3:T-child"])
        let child = parent.subagents[0]
        #expect(child.state == .running)
        #expect(child.nativeIds == [Fixture.codexChild])
        #expect(!threads.flatMap(\.subagents).contains { $0.id == Fixture.codexChild })

        // One token contribution each: parent 1500 (alias), child 200 (its own JSONL), project 1700.
        #expect(parent.tokensTotal == 1500)
        #expect(child.tokensTotal == 200)
        let attribution = LocalTokenAttribution(provider: .codex, usage: nil, projects: snapshot.projects, statuses: snapshot.statuses, now: now)
        #expect(attribution.projects.map(\.tokens) == [1700])

        // Correct project: the T3 project workspace root, not the JSONL cwd (/Users/me/Projects/beta).
        let project = try #require(snapshot.projects.first { $0.threads.contains { $0.id == parent.id } })
        #expect(project.identity.root == root)
        #expect(project.identity.kind == .t3)
        #expect(project.identity.name == "Recipes")
        #expect(project.owningApps == [.t3])

        // T3 routing: the exact-thread link names T3's environment and thread ids.
        let router = OpenRouter(capabilities: RoutingCapabilities(t3: .exactThread, codex: .appOnly, claudeCode: .appOnly))
        let expected = try #require(URL(string: "t3code://threads/\(T3Fixture.environmentId)/T-parent"))
        #expect(router.target(for: parent) == .link(expected, app: .t3Code))
        #expect(router.primaryTarget(for: project).thread?.id == "t3:T-parent")
        #expect(router.target(for: parent).label == "Open in T3 Code ↗")
    }

    @Test func claudeSessionAliasTakesTheT3TitleAndKeepsItsSubagentFile() async throws {
        let s = Scratch()
        s.installFixtures()
        let t3 = T3Fixture(s)
        let root = s.dir("Projects/notes")
        t3.project("p2", title: "Notes", root: root)
        t3.thread("T-claude", project: "p2", title: "Shelf polish", created: at("09:59:00"))
        t3.thread("T-claude-task", project: "p2", title: "reviewer", created: at("10:00:00"), parent: "T-claude")
        t3.mapping(thread: "T-claude", driver: "claudeAgent", nativeId: Fixture.claudeSession)
        t3.mapping(thread: "T-claude-task", driver: "claudeAgent", nativeId: Fixture.claudeSecond)
        t3.subagent("sa-2", parent: "T-claude", child: "T-claude-task", provider: "claudeAgent", status: "completed",
                    started: at("10:00:00"), updated: at("10:02:00"), completed: at("10:02:00"))
        let snapshot = await engine(s, t3).pass(now: now)
        let threads = snapshot.projects.flatMap(\.threads)
        let parent = try #require(threads.first { $0.id == "t3:T-claude" })
        #expect(parent.displayTitle == "Shelf polish")
        #expect(!threads.contains { $0.id == "claude:\(Fixture.claudeSession)" || $0.id == "claude:\(Fixture.claudeSecond)" })
        #expect(Set(parent.subagents.map(\.id)) == ["t3:T-claude-task", "abc123"])
        #expect(parent.subagents.first { $0.id == "t3:T-claude-task" }?.state == .idle)
        #expect(parent.primaryProvider == .claude)
        #expect(parent.tokensTotal == 215)
    }

    @Test func bindingStillWinsOverTheT3Project() async throws {
        let s = Scratch()
        let (t3, _) = codexAliasFixture(s)
        let store = try Store(url: s.url.appendingPathComponent("app/lighthouse.sqlite"))
        let bound = ProjectResolver.standardize(s.dir("Projects/bound"))
        try store.saveBinding(ProjectBinding(folder: s.path + "/Projects/recipes", projectRoot: bound))
        let snapshot = await engine(s, t3, store: store).pass(now: now)
        let project = try #require(snapshot.projects.first { $0.threads.contains { $0.id == "t3:T-parent" } })
        #expect(project.identity.root == bound)
        #expect(project.identity.kind == .bound)
    }

    // MARK: Attention (§5.4 waiting and silent)

    @Test func pendingApprovalOnALiveRunWaitsAndALeftoverDoesNot() async throws {
        let s = Scratch()
        let t3 = T3Fixture(s)
        t3.project("p", title: "P", root: s.dir("Projects/p"))
        t3.thread("live", project: "p", title: "Live thread", created: at("10:00:00"))
        t3.run(thread: "live", ordinal: 1, status: "running", requested: at("10:05:00"))
        t3.request("req-1", thread: "live", kind: "command", created: at("10:06:00"))
        t3.thread("old", project: "p", title: "Old thread", created: at("09:00:00"))
        t3.run(thread: "old", ordinal: 1, status: "completed", requested: at("09:00:00"), completed: at("09:10:00"))
        t3.request("req-old", thread: "old", kind: "user_input", created: at("09:05:00"))
        let snapshot = await Engine(collectors: [], store: nil, home: s.path, t3: T3Collector(reader: T3Reader(t3Home: t3.home))).pass(now: now)
        let project = try #require(snapshot.projects.first)
        let live = try #require(project.threads.first { $0.t3ThreadId == "live" })
        let old = try #require(project.threads.first { $0.t3ThreadId == "old" })
        #expect(live.state == .waitingForOwner)
        #expect(old.state == .idle)
        #expect(project.status == .needsYou)
        #expect(project.attention == ["Approval requested · Live thread"])
        #expect(project.attentionItems.map(\.id) == ["waitingForOwner|t3:live|req-1"])
        #expect(!project.attention.joined().contains(Fixture.bodyCanary))
    }

    @Test func silentSubagentRaisesOneIncidentThatAcknowledgeHidesAndNewActivityClears() async throws {
        let s = Scratch()
        let t3 = T3Fixture(s)
        t3.project("p", title: "P", root: s.dir("Projects/p"))
        t3.thread("parent", project: "p", title: "Parent", created: at("09:00:00"))
        t3.run(thread: "parent", ordinal: 1, status: "running", requested: at("09:00:00"))
        t3.thread("kid", project: "p", title: "coder", created: at("09:01:00"), parent: "parent")
        t3.subagent("sa", parent: "parent", child: "kid", provider: "codex", status: "running", started: at("09:01:00"), updated: at("09:30:00"))
        let store = try Store(url: s.url.appendingPathComponent("app/lighthouse.sqlite"))
        let engine = Engine(collectors: [], store: store, home: s.path, t3: T3Collector(reader: T3Reader(t3Home: t3.home), minInterval: 0))

        // 40 min of silence at 10:10: one item, entered at 10:00.
        var project = try #require(await engine.pass(now: now).projects.first)
        #expect(project.attention == ["1 subagent silent · 40 m"])
        let incident = try #require(project.attentionItems.first)
        #expect(incident.kind == .silentSubagent)
        #expect(incident.id == "silentSubagent|t3:kid|\(Int(at("10:00:00").timeIntervalSince1970))")

        // Acknowledge hides that incident identity only, and persists in the store.
        try store.acknowledge(incident.id)
        project = try #require(await engine.pass(now: now.addingTimeInterval(60)).projects.first)
        #expect(project.attentionItems.isEmpty)
        #expect(try store.loadAcknowledgements() == [incident.id])

        // New activity clears the condition while the subagent stays running.
        t3.exec("UPDATE orchestration_v2_projection_subagents SET updated_at = '\(T3Fixture.iso(at("10:12:00")))'")
        let later = at("10:20:00")
        project = try #require(await engine.pass(now: later).projects.first)
        #expect(project.threads[0].subagents[0].state == .running)
        #expect(project.attentionItems.isEmpty)
        // A later silence is a new incident, shown even though the first was acknowledged.
        // M4: passes every 4 min, as the live loop runs; a pass gap over 5 min is unobserved time (sleep).
        for minute in stride(from: 24, through: 48, by: 4) { _ = await engine.pass(now: at("10:\(minute):00")) }
        project = try #require(await engine.pass(now: at("10:50:00")).projects.first)
        #expect(project.attentionItems.count == 1)
        #expect(project.attentionItems[0].id != incident.id)
    }

    @Test func staleT3ReadNeverRaisesSilence() async throws {
        let s = Scratch()
        let t3 = T3Fixture(s)
        t3.project("p", title: "P", root: s.dir("Projects/p"))
        t3.thread("parent", project: "p", title: "Parent", created: at("09:00:00"))
        t3.thread("kid", project: "p", title: "coder", created: at("09:01:00"), parent: "parent")
        t3.subagent("sa", parent: "parent", child: "kid", provider: "codex", status: "running", started: at("09:01:00"), updated: at("09:01:00"))
        let collector = T3Collector(reader: T3Reader(t3Home: t3.home), minInterval: 0)
        let engine = Engine(collectors: [], store: nil, home: s.path, t3: collector)
        _ = await engine.pass(now: at("09:02:00"))
        // T3 becomes unreadable: the last state is kept but its read is stale, so it is unknown.
        t3.remove("-wal", "-shm")
        let project = try #require(await engine.pass(now: now).projects.first)
        #expect(project.threads[0].subagents[0].state == .unknown)
        #expect(project.attentionItems.isEmpty)
        #expect(await engine.pass(now: now).statuses.first { $0.source == .t3 }?.error?.contains("WAL/SHM") == true)
    }

    // MARK: Repair round 1

    enum ShmBreak: CaseIterable { case removed, truncated }

    /// M3-R01: an unchanged database and WAL must not renew freshness when `-shm` is gone or truncated.
    @Test(arguments: ShmBreak.allCases)
    func brokenShmAfterAGoodReadIsUnavailableNotFresh(_ breakage: ShmBreak) async throws {
        let s = Scratch()
        let (t3, _) = codexAliasFixture(s)
        let collector = T3Collector(reader: T3Reader(t3Home: t3.home), minInterval: 0)
        let engine = Engine(collectors: [], store: nil, home: s.path, t3: collector)
        let good = await engine.pass(now: now)
        #expect(good.statuses.first { $0.source == .t3 }?.error == nil)
        switch breakage {
        case .removed: try FileManager.default.removeItem(atPath: t3.databasePath + "-shm")
        case .truncated: s.write("t3/userdata/statev2.sqlite-shm", "")
        }
        let soon = await collector.pass(now: now.addingTimeInterval(60))
        #expect(soon.readAt == now)
        #expect(soon.status.lastReadAt == now)
        #expect(soon.status.error?.contains("WAL/SHM pair inconsistent") == true)
        // The child (running, last activity 10:01:05) would be silent at 10:45 if T3 still looked fresh.
        let later = await engine.pass(now: at("10:45:00"))
        let status = try #require(later.statuses.first { $0.source == .t3 })
        #expect(status.lastReadAt == now)
        #expect(status.error?.contains("WAL/SHM pair inconsistent") == true)
        let parent = try #require(later.projects.flatMap(\.threads).first { $0.id == "t3:T-parent" })
        #expect(parent.state == .unknown)
        #expect(parent.subagents.allSatisfy { $0.state == .unknown })
        #expect(later.projects.allSatisfy { $0.attentionItems.isEmpty })
    }

    /// M3-R02: a JSONL child that T3 maps under a T3 parent is removed from its unmapped JSONL parent.
    @Test func mappedChildOfAnUnmappedParentAppearsAndCountsOnce() async throws {
        let s = Scratch()
        s.installFixtures()
        s.append("codex/sessions/2026/10/29/rollout-2026-10-29T10-01-00-\(Fixture.codexChild).jsonl",
                 #"{"timestamp":"2026-10-29T10:01:05.000Z","ordinal":2,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":200}}}}"# + "\n")
        let t3 = T3Fixture(s)
        t3.project("p1", title: "Recipes", root: s.dir("Projects/recipes"))
        t3.thread("T-parent", project: "p1", title: "Recipe card layout", created: at("10:00:00"))
        t3.thread("T-child", project: "p1", title: "coder", created: at("10:01:00"), parent: "T-parent")
        t3.mapping(thread: "T-child", driver: "codex", nativeId: Fixture.codexChild)   // parent 001 stays unmapped
        t3.subagent("sa-1", parent: "T-parent", child: "T-child", provider: "codex", status: "running", started: at("10:01:00"), updated: at("10:01:05"))
        t3.close()
        let snapshot = await engine(s, t3).pass(now: now)
        let threads = snapshot.projects.flatMap(\.threads)
        let occurrences = threads.flatMap(\.subagents).filter { $0.id == Fixture.codexChild || $0.nativeIds.contains(Fixture.codexChild) }
        #expect(occurrences.map(\.id) == ["t3:T-child"])
        let jsonlParent = try #require(threads.first { $0.id == "codex:\(Fixture.codexParent)" })
        #expect(jsonlParent.subagents.isEmpty)
        let attribution = LocalTokenAttribution(provider: .codex, usage: nil, projects: snapshot.projects, statuses: snapshot.statuses, now: now)
        #expect(attribution.projects.reduce(0) { $0 + $1.tokens } == 1700)   // parent 1500 + child 200, once
    }

    /// M3-R03: a T3 child mapped to a Codex and a Claude session counts each once, under its own provider.
    @Test func mixedProviderChildKeepsBothProvidersTokensOnce() async throws {
        let s = Scratch()
        let (t3, _) = codexAliasFixture(s)
        t3.mapping(thread: "T-child", driver: "claudeAgent", nativeId: Fixture.claudeSecond)
        t3.close()
        s.append("claude/-Users-me-Projects-alpha/\(Fixture.claudeSecond).jsonl",
                 #"{"type":"assistant","sessionId":"\#(Fixture.claudeSecond)","timestamp":"2026-10-29T10:03:00.000Z","message":{"id":"msg-mixed-1","role":"assistant","stop_reason":"end_turn","usage":{"input_tokens":30,"output_tokens":20}}}"# + "\n")
        let snapshot = await engine(s, t3).pass(now: now)
        let threads = snapshot.projects.flatMap(\.threads)
        #expect(!threads.contains { $0.id == "claude:\(Fixture.claudeSecond)" })
        let parent = try #require(threads.first { $0.id == "t3:T-parent" })
        let child = try #require(parent.subagents.first { $0.id == "t3:T-child" })
        #expect(child.provider == .codex)
        #expect(child.tokensTotal == 200)
        let claudeSecond = try #require(await ClaudeCodeCollector(root: s.claudeRoot).pass(now: now).threads.first { $0.sessionId == Fixture.claudeSecond })
        let claudeTokens = try #require(claudeSecond.tokensTotal)
        #expect(claudeTokens == 50)
        #expect(child.otherProviderTokens[.claude]?.total == claudeSecond.tokenBuckets.total)
        let wide = DateInterval(start: at("09:00:00"), end: at("11:00:00"))
        #expect(LocalTokenAttribution.tokens(parent, provider: .codex, in: wide) == 1700)
        #expect(LocalTokenAttribution.tokens(parent, provider: .claude, in: wide) == claudeSecond.tokenBuckets.sum(in: wide))
    }

    /// M3-R04: a statement still running at the deadline is interrupted by the progress handler, the
    /// transaction and connection close, and the pass is rejected. Without the handler the slow
    /// statement runs to completion first (mutation-checked in the M3 receipt).
    @Test func deadlineInterruptsAStatementThatIsStillRunning() async throws {
        let s = Scratch()
        let (t3, _) = codexAliasFixture(s)
        // Make the runs query quadratic: many runs of one thread and no (thread_id, ordinal) index.
        t3.exec("""
            DROP INDEX runs_thread_ordinal;
            WITH RECURSIVE n(i) AS (SELECT 2 UNION ALL SELECT i + 1 FROM n WHERE i < 9000)
            INSERT INTO orchestration_v2_projection_runs (run_id, thread_id, ordinal, status, requested_at)
            SELECT 'slow-' || i, 'T-parent', i, 'completed', '2026-10-29T10:00:00.000Z' FROM n;
            """)
        t3.close()
        let unbounded = DispatchTime.now().uptimeNanoseconds
        _ = try T3Reader(t3Home: t3.home, deadline: 600).read().get()
        let fullSeconds = Double(DispatchTime.now().uptimeNanoseconds - unbounded) / 1e9
        #expect(fullSeconds > 1.5, "fixture too fast to prove interruption: \(fullSeconds) s")

        let reader = T3Reader(t3Home: t3.home, deadline: 0.5)
        let modes = OpenModes()
        let started = DispatchTime.now().uptimeNanoseconds
        let result = reader.read()
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
        #expect(result == .failure(.deadline))
        #expect(seconds < 1.5, "statement ran \(seconds) s past a 0.5 s deadline (full run \(fullSeconds) s)")
        // Transaction and connection closed: no descriptor of this process still holds the database.
        modes.capture(pid: getpid(), matching: t3.databasePath)
        #expect(modes.files.isEmpty, "\(modes.files)")
        // Pass rejected: a collector keeps no state from the interrupted read.
        let collector = T3Collector(reader: T3Reader(t3Home: t3.home, deadline: 0.5), minInterval: 0)
        let pass = await collector.pass(now: now)
        #expect(pass.state == nil && pass.readAt == nil)
        #expect(pass.status.error?.contains("deadline") == true)
    }

    // MARK: Acceptance (2): fail closed, no copy, no write, no fallback read path

    enum Breakage: CaseIterable { case walMissing, shmMissing, shmUninitialized, walHeaderInvalid, unknownSchema, deadline }

    @Test(arguments: Breakage.allCases)
    func brokenSourcesSkipThePassWithoutCopyWriteOrFallback(_ breakage: Breakage) async throws {
        let s = Scratch()
        let (t3, _) = codexAliasFixture(s)
        var clock: SteppingClock?
        switch breakage {
        case .walMissing:
            t3.remove("-wal", "-shm")   // The header still says WAL.
        case .shmMissing:
            t3.remove("-shm")
        case .shmUninitialized:
            t3.remove("-shm")
            s.write("t3/userdata/statev2.sqlite-shm", "x")
        case .walHeaderInvalid:
            t3.remove("-wal")
            s.write("t3/userdata/statev2.sqlite-wal", String(repeating: "z", count: 64))
        case .unknownSchema:
            t3.exec("ALTER TABLE orchestration_v2_projection_subagents RENAME COLUMN child_thread_id TO child_id")
            t3.close()
        case .deadline:
            clock = SteppingClock(step: 6)   // 15 s pass after the third reading
        }
        let before = treeFingerprint(t3.home)
        let entriesBefore = Set(FileManager.default.subpaths(atPath: t3.home) ?? [])
        let access = RecordingAccess()
        let appDir = s.url.appendingPathComponent("app")
        let store = try Store(url: appDir.appendingPathComponent("lighthouse.sqlite"))
        let tick: (@Sendable () -> Double)? = clock.map { c in { @Sendable in c.read() } }
        let snapshot = await self.engine(s, t3, access: access, store: store, clock: tick).pass(now: now)

        // Pass skipped: no T3 thread, the JSONL sessions stay as they are, one error line.
        let threads = snapshot.projects.flatMap(\.threads)
        #expect(!threads.contains { $0.owningApp == .t3 && $0.t3ThreadId != nil })
        #expect(threads.contains { $0.id == "codex:\(Fixture.codexParent)" })
        let status = try #require(snapshot.statuses.first { $0.source == .t3 })
        let error = try #require(status.error)
        switch breakage {
        case .walMissing, .shmMissing, .shmUninitialized, .walHeaderInvalid: #expect(error.contains("WAL/SHM pair inconsistent"))
        case .unknownSchema: #expect(error.contains("schema not recognized"))
        case .deadline: #expect(error.contains("deadline"))
        }
        // No write: every T3 file is byte-identical and no file was created (no copy, journal or sidecar).
        #expect(treeFingerprint(t3.home) == before)
        #expect(Set(FileManager.default.subpaths(atPath: t3.home) ?? []) == entriesBefore)
        // No copy: the app folder holds only the store.
        let appFiles = Set(FileManager.default.subpaths(atPath: appDir.path) ?? [])
        #expect(appFiles.isSubset(of: ["lighthouse.sqlite", "lighthouse.sqlite-wal", "lighthouse.sqlite-shm"]))
        // No fallback read path: the reader touched only the database, its sidecars and the environment id.
        let allowed = Set(["", "-wal", "-shm", "-journal"].map { t3.databasePath + $0 } + [t3.home + "/userdata/environment-id"])
        #expect(Set(access.operations.map(\.path)).isSubset(of: allowed))
        #expect(Set(access.operations.map(\.op)).isSubset(of: ["stat", "read"]))
    }

    @Test func failedReadKeepsTheLastGoodStateAndDoesNotReadAgainElsewhere() async throws {
        let s = Scratch()
        let (t3, _) = codexAliasFixture(s)
        let collector = T3Collector(reader: T3Reader(t3Home: t3.home), minInterval: 0)
        let good = await collector.pass(now: now)
        #expect(good.state != nil && good.status.error == nil)
        t3.exec("DROP TABLE orchestration_v2_projection_runtime_requests")
        let failed = await collector.pass(now: now.addingTimeInterval(30))
        #expect(failed.readAt == now)
        #expect(failed.state == good.state)
        #expect(failed.status.error?.contains("runtime_requests missing") == true)
    }

    @Test func unchangedDatabaseIsConfirmedByStatWithoutOpeningIt() async throws {
        let s = Scratch()
        let (t3, _) = codexAliasFixture(s)
        let access = RecordingAccess()
        var reader = T3Reader(t3Home: t3.home, access: access)
        let opens = Counter()
        reader.whileOpen = { opens.increment() }
        let collector = T3Collector(reader: reader, minInterval: 0)
        let first = await collector.pass(now: now)
        #expect(opens.value == 1)
        let count = access.operations.count
        let second = await collector.pass(now: now.addingTimeInterval(120))
        #expect(second.readAt == now.addingTimeInterval(120))
        #expect(second.state == first.state)
        // Stat plus the sidecar preflight (M3-R01); SQLite is not opened.
        #expect(opens.value == 1)
        #expect(access.operations.dropFirst(count).allSatisfy { $0.op == "stat" || $0.op == "read" })
        // A commit changes the WAL: the next pass reads again and sees it.
        t3.exec("UPDATE orchestration_v2_projection_threads SET title = 'Renamed' WHERE thread_id = 'T-parent'")
        t3.close()
        let third = await collector.pass(now: now.addingTimeInterval(240))
        #expect(third.state?.threads.first { $0.id == "T-parent" }?.title == "Renamed")
    }

    // MARK: Read-only in place on success

    /// T3 running in another process with live WAL frames: the read leaves every T3 byte unchanged
    /// (the shared-memory index is mapped read-only) and creates no file.
    @Test func successfulReadWritesNothingAndCreatesNoFile() async throws {
        let s = Scratch()
        let (t3, _) = codexAliasFixture(s)
        let writer = try ExternalWriter(database: t3.databasePath)
        defer { writer.stop() }
        writer.run("PRAGMA journal_mode = WAL; UPDATE orchestration_v2_projection_threads SET updated_at = updated_at || ''")
        let before = treeFingerprint(t3.home)
        let entries = Set(FileManager.default.subpaths(atPath: t3.home) ?? [])
        #expect(entries.contains("userdata/statev2.sqlite-wal") && entries.contains("userdata/statev2.sqlite-shm"))
        var reader = T3Reader(t3Home: t3.home)
        let modes = OpenModes()
        let databasePath = t3.databasePath
        reader.whileOpen = { modes.capture(pid: getpid(), matching: databasePath) }
        let state = try reader.read().get()
        // The database, its WAL and its shared-memory index are all open read-only (lsof mode `r`).
        #expect(Set(modes.files.keys) == Set(["", "-wal", "-shm"].map { ProjectResolver.standardize(t3.databasePath + $0) }), "\(modes.files)")
        #expect(modes.files.values.allSatisfy { $0 == "r" }, "\(modes.files)")
        #expect(state.threads.count == 2 && state.environmentId == T3Fixture.environmentId)
        let after = treeFingerprint(t3.home)
        #expect(after == before, "\(after.filter { before[$0.key] != $0.value }) vs \(before.filter { after[$0.key] != $0.value })")
        #expect(Set(FileManager.default.subpaths(atPath: t3.home) ?? []) == entries)
    }

    @Test func readerSelectsNoTextColumns() {
        let sql = T3Reader.queries.joined(separator: "\n").lowercased()
        for word in ["prompt", "result", "messages", "question", "answers", "decision", "feedback", "goal", "text"] {
            #expect(!sql.contains(word), "query selects \(word)")
        }
        // payload_json is only parsed for two id/path fields, never returned.
        let selected = sql.components(separatedBy: "payload_json").count - 1
        let extracted = sql.components(separatedBy: "json_extract(payload_json").count - 1 + sql.components(separatedBy: "json_valid(payload_json").count - 1
        #expect(selected == extracted)
    }

    @Test func canariesInT3TextNeverReachTheStore() async throws {
        let s = Scratch()
        let (t3, _) = codexAliasFixture(s)
        t3.request("req-c", thread: "T-parent", kind: "user_input", created: at("10:02:00"))
        let dir = s.url.appendingPathComponent("AppSupport/Lighthouse")
        let store = try Store(url: dir.appendingPathComponent("lighthouse.sqlite"))
        let snapshot = await self.engine(s, t3, store: store).indexToCompletion()
        let project = try #require(snapshot.projects.first { $0.threads.contains { $0.id == "t3:T-parent" } })
        for item in project.attentionItems { try store.acknowledge(item.id) }
        for thread in snapshot.projects.flatMap(\.threads) {
            #expect(!(thread.title ?? "").contains(Fixture.bodyCanary))
        }
        let files = (FileManager.default.enumerator(atPath: dir.path)?.allObjects as? [String] ?? []).map { dir.appendingPathComponent($0).path }
        for file in files {
            #expect(!bytesContain(file, Fixture.bodyCanary), "body canary in \(file)")
            #expect(!bytesContain(file, Fixture.secretCanary), "secret canary in \(file)")
        }
    }

    @Test func environmentIdIsValidatedAndMissingIdFallsBackToAppOnly() async throws {
        let s = Scratch()
        s.installFixtures()
        let t3 = T3Fixture(s, environmentId: nil)
        t3.project("p", title: "P", root: s.dir("Projects/p"))
        t3.thread("x", project: "p", title: "X", created: at("10:00:00"))
        let snapshot = await engine(s, t3).pass(now: now)
        let thread = try #require(snapshot.projects.flatMap(\.threads).first { $0.t3ThreadId == "x" })
        #expect(thread.t3EnvironmentId == nil)
        let router = OpenRouter(capabilities: RoutingCapabilities(t3: .exactThread, codex: .appOnly, claudeCode: .appOnly))
        #expect(router.target(for: thread) == .app(.t3Code, sessionId: "x"))
    }
}
