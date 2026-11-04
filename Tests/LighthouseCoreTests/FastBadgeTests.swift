import Foundation
import Testing
@testable import LighthouseCore

/// SPEC 2.13: targeted T3 refresh of the threads behind open Needs-you items. Fixture data only.
@Suite struct FastBadgeTests {
    func at(_ time: String) -> Date { Fixture.date("2026-10-29T\(time).000Z") }

    func waiting(_ snapshot: Snapshot) -> [String] {
        snapshot.projects.flatMap(\.attentionItems).filter { $0.kind == .waitingForOwner }.map(\.id).sorted()
    }

    func makeEngine(_ t3: T3Fixture, collectors: [any SessionCollector] = [], home: String, access: SourceAccess = ReadOnlyFileSystem()) -> (Engine, T3Collector) {
        let collector = T3Collector(reader: T3Reader(t3Home: t3.home, access: access), minInterval: 60, subjectSpacing: 0)
        return (Engine(collectors: collectors, store: nil, home: home, t3: collector), collector)
    }

    func parentWaiting(_ s: Scratch) -> T3Fixture {
        let t3 = T3Fixture(s)
        t3.project("p", title: "P", root: s.dir("Projects/p"))
        t3.thread("T1", project: "p", title: "Asks", created: at("09:00:00"))
        t3.run(thread: "T1", ordinal: 1, status: "running", requested: at("09:00:00"))
        t3.request("req-1", thread: "T1", kind: "command", created: at("09:01:00"))
        return t3
    }

    func resolve(_ t3: T3Fixture, _ id: String) {
        t3.exec("UPDATE orchestration_v2_projection_runtime_requests SET status = 'resolved' WHERE runtime_request_id = '\(id)'")
    }

    // MARK: C2 correctness

    @Test func resolvedParentRequestLeavesTheCountWithoutAFullRead() async throws {
        let s = Scratch()
        let t3 = parentWaiting(s)
        let (engine, collector) = makeEngine(t3, home: s.path)
        let first = await engine.pass(now: at("09:02:00"))
        #expect(waiting(first) == ["waitingForOwner|t3:T1|req-1"])
        #expect(await engine.t3Subjects == ["T1"])
        let readAt = try #require(first.projects.first?.threads.first?.sourceReadAt)

        // Nothing committed: two stats, no SQL.
        #expect(await engine.refreshT3Subjects() == false)
        #expect(await collector.subjectReads == 0)

        resolve(t3, "req-1")
        #expect(await engine.refreshT3Subjects())
        let after = await engine.resolvedSnapshot(now: at("09:02:01"))
        #expect(waiting(after).isEmpty)
        #expect(after.projects.first?.threads.first?.state == .running)
        // Freshness is the full read's: a partial read never renews it.
        #expect(after.projects.first?.threads.first?.sourceReadAt == readAt)
        #expect(await collector.reads == 1)
        #expect(await collector.subjectReads == 1)
        #expect(await engine.t3Subjects.isEmpty)
        // Nothing counted any more: no read even after a later commit.
        t3.request("req-other", thread: "T1", kind: "command", status: "resolved", created: at("09:03:00"))
        #expect(await engine.refreshT3Subjects() == false)
        #expect(await collector.subjectReads == 1)
    }

    @Test func resolvedChildRequestLeavesTheCount() async throws {
        let s = Scratch()
        let t3 = T3Fixture(s)
        t3.project("p", title: "P", root: s.dir("Projects/p"))
        t3.thread("T1", project: "p", title: "Parent", created: at("09:00:00"))
        t3.run(thread: "T1", ordinal: 1, status: "running", requested: at("09:00:00"))
        t3.thread("T2", project: "p", title: "Child", created: at("09:00:30"), parent: "T1")
        t3.run(thread: "T2", ordinal: 1, status: "running", requested: at("09:00:30"))
        t3.subagent("s1", parent: "T1", child: "T2", provider: "codex", status: "running", started: at("09:00:30"), updated: at("09:01:00"))
        t3.request("req-c", thread: "T2", kind: "user-input", created: at("09:01:00"))
        let (engine, _) = makeEngine(t3, home: s.path)
        #expect(waiting(await engine.pass(now: at("09:02:00"))) == ["waitingForOwner|t3:T2|req-c"])
        #expect(await engine.t3Subjects == ["T2"])

        resolve(t3, "req-c")
        #expect(await engine.refreshT3Subjects())
        let after = await engine.resolvedSnapshot(now: at("09:02:01"))
        #expect(waiting(after).isEmpty)
        #expect(after.projects.first?.threads.first?.subagents.first?.state == .running)
    }

    @Test func replacementRequestKeepsOneItemWithTheNewId() async throws {
        let s = Scratch()
        let t3 = parentWaiting(s)
        let (engine, _) = makeEngine(t3, home: s.path)
        _ = await engine.pass(now: at("09:02:00"))
        resolve(t3, "req-1")
        t3.request("req-2", thread: "T1", kind: "command", created: at("09:02:00"))
        #expect(await engine.refreshT3Subjects())
        #expect(waiting(await engine.resolvedSnapshot(now: at("09:02:01"))) == ["waitingForOwner|t3:T1|req-2"])
    }

    @Test func endedRunAndDeletedThreadLeaveTheCount() async throws {
        let s = Scratch()
        let t3 = parentWaiting(s)
        let (engine, _) = makeEngine(t3, home: s.path)
        _ = await engine.pass(now: at("09:02:00"))
        // The request row stays pending, but the run ended: a leftover, not a wait.
        t3.exec("UPDATE orchestration_v2_projection_runs SET status = 'completed', completed_at = '\(T3Fixture.iso(at("09:02:00")))'")
        #expect(await engine.refreshT3Subjects())
        #expect(waiting(await engine.resolvedSnapshot(now: at("09:02:01"))).isEmpty)

        let s2 = Scratch()
        let t3b = parentWaiting(s2)
        let (engine2, _) = makeEngine(t3b, home: s2.path)
        _ = await engine2.pass(now: at("09:02:00"))
        t3b.exec("UPDATE orchestration_v2_projection_threads SET deleted_at = '\(T3Fixture.iso(at("09:02:00")))'")
        #expect(await engine2.refreshT3Subjects())
        let after = await engine2.resolvedSnapshot(now: at("09:02:01"))
        #expect(waiting(after).isEmpty)
        #expect(after.projects.flatMap(\.threads).isEmpty)
    }

    /// A Codex session mapped to T3 thread T1 whose turn ended asking the owner.
    func replyFixture(_ s: Scratch) -> (T3Fixture, String) {
        let cwd = s.dir("Projects/r")
        let ask = #"{"timestamp":"2026-10-29T09:05:00.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done with the change. Should I push it to main?"}]}}"#
        s.write(M4Tests.rollout("c-reply"), M4Tests.meta("c-reply", cwd: cwd, time: "09:00:00", originator: "T3 Code")
                + M4Tests.event("task_started", "09:00:01") + ask + "\n" + M4Tests.event("task_complete", "09:05:01"))
        let t3 = T3Fixture(s)
        t3.project("p", title: "P", root: cwd)
        t3.thread("T1", project: "p", title: "Reply", created: at("09:00:00"))
        t3.mapping(thread: "T1", driver: "codex", nativeId: "c-reply")
        t3.run(thread: "T1", ordinal: 1, status: "completed", requested: at("09:00:00"), completed: at("09:05:01"))
        return (t3, cwd)
    }

    @Test func replyHandOffClearsWhenANewRunStarts() async throws {
        let s = Scratch()
        let (t3, _) = replyFixture(s)
        let (engine, _) = makeEngine(t3, collectors: [CodexCollector(codexHome: s.codexHome)], home: s.path)
        let first = await engine.pass(now: at("09:06:00"))
        #expect(waiting(first).count == 1)
        #expect(waiting(first).first?.contains("reply-") == true)
        #expect(await engine.t3Subjects == ["T1"])

        // The owner answered in T3: a new run is active, so the next move is the agent's.
        t3.run(thread: "T1", ordinal: 2, status: "running", requested: at("09:06:30"))
        #expect(await engine.refreshT3Subjects())
        let after = await engine.resolvedSnapshot(now: at("09:06:31"))
        #expect(waiting(after).isEmpty)
        #expect(after.projects.flatMap(\.threads).first?.state == .running)
    }

    /// A T3-owned running Codex thread, stalled since 09:05, with three nudges sent.
    func stalledNudged(_ s: Scratch) async -> (T3Fixture, Engine, T3Collector, Snapshot) {
        let cwd = s.dir("Projects/n")
        s.write(M4Tests.rollout("c-stall"), M4Tests.meta("c-stall", cwd: cwd, time: "09:00:00", originator: "T3 Code")
                + M4Tests.event("task_started", "09:00:01") + M4Tests.tokens(100, "09:05:00"))
        let t3 = T3Fixture(s)
        t3.project("p", title: "P", root: cwd)
        t3.thread("T1", project: "p", title: "Stuck", created: at("09:00:00"))
        t3.mapping(thread: "T1", driver: "codex", nativeId: "c-stall")
        t3.run(thread: "T1", ordinal: 1, status: "running", requested: at("09:00:00"))
        let collector = T3Collector(reader: T3Reader(t3Home: t3.home), minInterval: 0, subjectSpacing: 0)
        let engine = Engine(collectors: [CodexCollector(codexHome: s.codexHome)], store: nil, home: s.path, t3: collector)
        await engine.setNudges(["t3:T1": NudgeRecord(threadId: "T1", episodeStart: at("09:45:00"), count: 3, lastSentAt: at("10:00:00"))])
        var t = at("09:10:00")
        var last = await engine.pass(now: t)
        while t < at("10:30:00") {
            t = t.addingTimeInterval(240)
            last = await engine.pass(now: t)
        }
        return (t3, engine, collector, last)
    }

    @Test func exhaustedNudgeStaysWithoutProofAndClearsWhenTheRunEnds() async throws {
        let s = Scratch()
        let (t3, engine, collector, last) = await stalledNudged(s)
        let stuck = waiting(last)
        #expect(stuck.count == 1 && stuck.first?.contains("nudged-") == true)
        let now = last.checkedAt!

        // An unrelated commit is no progress proof: the item stays.
        t3.thread("T9", project: "p", title: "Other", created: at("10:20:00"))
        #expect(await engine.refreshT3Subjects() == false)
        #expect(await collector.subjectReads == 1)
        #expect(waiting(await engine.resolvedSnapshot(now: now)) == stuck)

        t3.exec("UPDATE orchestration_v2_projection_runs SET status = 'completed', completed_at = '\(T3Fixture.iso(now))' WHERE thread_id = 'T1'")
        #expect(await engine.refreshT3Subjects())
        #expect(waiting(await engine.resolvedSnapshot(now: now)).isEmpty)
    }

    // MARK: C6 failures and replacement

    /// Reads fail on demand (preflight cannot read the header), as with an unreadable database.
    final class FlakyAccess: SourceAccess, @unchecked Sendable {
        let inner = ReadOnlyFileSystem()
        private let lock = NSLock()
        private var _failing = false
        var failing: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _failing }
            set { lock.lock(); _failing = newValue; lock.unlock() }
        }
        func stat(_ path: String) -> FileStat? { inner.stat(path) }
        func list(_ directory: String) -> [String] { inner.list(directory) }
        func isReadable(_ path: String) -> Bool { inner.isReadable(path) }
        func read(_ path: String, offset: UInt64, count: Int) -> Data? { failing ? nil : inner.read(path, offset: offset, count: count) }
        func scan(_ root: String, ext: String, skipping: Set<String>) -> (files: [ScannedFile], symlinks: Int) {
            inner.scan(root, ext: ext, skipping: skipping)
        }
    }

    @Test func failedTargetedReadKeepsTheItemAndRetriesBoundedly() async throws {
        let s = Scratch()
        let t3 = parentWaiting(s)
        let access = FlakyAccess()
        let (engine, collector) = makeEngine(t3, home: s.path, access: access)
        let first = await engine.pass(now: at("09:02:00"))
        let readAt = first.projects.first?.threads.first?.sourceReadAt

        access.failing = true
        resolve(t3, "req-1")
        for _ in 0..<5 { #expect(await engine.refreshT3Subjects() == false) }
        // Unresolved attention is kept, and the retry at the same commit is bounded.
        let kept = await engine.resolvedSnapshot(now: at("09:02:01"))
        #expect(waiting(kept) == ["waitingForOwner|t3:T1|req-1"])
        #expect(kept.projects.first?.threads.first?.sourceReadAt == readAt)
        #expect(await collector.subjectReads == T3Collector.subjectRetries)
        #expect(await collector.lastError == nil)   // The status line belongs to the full read.

        access.failing = false
        t3.exec("UPDATE orchestration_v2_projection_threads SET title = 'Asks again' WHERE thread_id = 'T1'")   // the next commit
        #expect(await engine.refreshT3Subjects())
        #expect(waiting(await engine.resolvedSnapshot(now: at("09:02:02"))).isEmpty)
    }

    @Test func noTargetedReadOnTopOfAFailingFullRead() async throws {
        let s = Scratch()
        let t3 = parentWaiting(s)
        let access = FlakyAccess()
        let collector = T3Collector(reader: T3Reader(t3Home: t3.home, access: access), minInterval: 0)
        let engine = Engine(collectors: [], store: nil, home: s.path, t3: collector)
        _ = await engine.pass(now: at("09:02:00"))
        access.failing = true
        t3.exec("UPDATE orchestration_v2_projection_threads SET title = 'Asks 2'")
        _ = await engine.pass(now: at("09:03:00"))   // full read fails: the last state stays, error shown
        #expect(await collector.lastError != nil)
        access.failing = false
        resolve(t3, "req-1")
        #expect(await engine.refreshT3Subjects() == false)
        #expect(await collector.subjectReads == 0)
        #expect(waiting(await engine.resolvedSnapshot(now: at("09:03:01"))) == ["waitingForOwner|t3:T1|req-1"])
    }

    @Test func replacedDatabaseFileIsReadByPath() async throws {
        let s = Scratch()
        let t3 = parentWaiting(s)
        let (engine, _) = makeEngine(t3, home: s.path)
        _ = await engine.pass(now: at("09:02:00"))
        // A new database file (new inode) replaces the old one, as after a T3 restore or reset.
        let s2 = Scratch()
        let replacement = parentWaiting(s2)
        resolve(replacement, "req-1")
        replacement.close()
        t3.close()
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let target = t3.databasePath + suffix, source = replacement.databasePath + suffix
            try? fm.removeItem(atPath: target)
            if fm.fileExists(atPath: source) { try fm.moveItem(atPath: source, toPath: target) }
        }
        #expect(await engine.refreshT3Subjects())
        #expect(waiting(await engine.resolvedSnapshot(now: at("09:02:01"))).isEmpty)
    }

    // MARK: Reconciliation with full reads (C4)

    @Test func fullReadAfterATargetedPatchReadsAgainAndKeepsTheCadence() async throws {
        #expect(T3Collector.defaultMinInterval == 60)
        let s = Scratch()
        let t3 = parentWaiting(s)
        let (engine, collector) = makeEngine(t3, home: s.path)
        _ = await engine.pass(now: at("09:02:00"))
        resolve(t3, "req-1")
        #expect(await engine.refreshT3Subjects())
        // Inside the 60 s interval the full pass is throttled and must not bring back the old state.
        let throttled = await engine.pass(now: at("09:02:30"))
        #expect(waiting(throttled).isEmpty)
        #expect(await collector.reads == 1)
        // After the interval the full read runs (the database changed since its last read).
        t3.request("req-3", thread: "T1", kind: "approval", created: at("09:03:00"))
        let full = await engine.pass(now: at("09:03:10"))
        #expect(await collector.reads == 2)
        #expect(waiting(full) == ["waitingForOwner|t3:T1|req-3"])
    }

    @Test func applyMatchesAFullRead() throws {
        // The patched state for a subject equals what a full read shows for it.
        let s = Scratch()
        let t3 = parentWaiting(s)
        t3.thread("T2", project: "p", title: "Other", created: at("09:00:00"))
        t3.request("req-x", thread: "T2", kind: "command", created: at("09:01:00"))
        let reader = T3Reader(t3Home: t3.home)
        var patched = try reader.read().get()
        resolve(t3, "req-1")
        t3.request("req-2", thread: "T1", kind: "approval", created: at("09:02:00"))
        t3.exec("UPDATE orchestration_v2_projection_threads SET archived_at = '\(T3Fixture.iso(at("09:02:00")))' WHERE thread_id = 'T1'")
        t3.run(thread: "T1", ordinal: 2, status: "running", requested: at("09:02:00"))
        let subjects = try reader.readSubjects(["T1"]).get()
        #expect(T3Collector.apply(subjects, to: &patched))
        let full = try reader.read().get()
        #expect(patched.runs == full.runs)
        #expect(Set(patched.pendingRequests) == Set(full.pendingRequests))
        #expect(patched.threads == full.threads)
        #expect(T3Collector.apply(subjects, to: &patched) == false)
    }

    @Test func targetedReadsAreSpacedHalfASecondApart() async throws {
        #expect(T3Collector.defaultSubjectSpacing == 0.5)
        let s = Scratch()
        let t3 = parentWaiting(s)
        let collector = T3Collector(reader: T3Reader(t3Home: t3.home), minInterval: 60)
        _ = await collector.pass(now: at("09:02:00"))
        t3.thread("T7", project: "p", title: "Other", created: at("09:02:00"))
        #expect(await collector.refreshSubjects(["T1"]) == nil)   // read, no change
        #expect(await collector.subjectReads == 1)
        resolve(t3, "req-1")
        #expect(await collector.refreshSubjects(["T1"]) == nil)   // inside the spacing: no read yet
        #expect(await collector.subjectReads == 1)
        try await Task.sleep(for: .milliseconds(550))
        #expect(await collector.refreshSubjects(["T1"]) != nil)   // the commit is not lost
        #expect(await collector.subjectReads == 2)
    }

    @Test func targetedQueriesSelectNoTextColumns() {
        for query in T3Reader.subjectQueries {
            for column in ["text", "prompt", "result", "question"] {
                #expect(!query.contains(column), "\(column) in \(query)")
            }
            // SPEC 2.14: payload_json is only parsed for the settle mark, never returned (the same
            // rule as the full read's `readerSelectsNoTextColumns`).
            let selected = query.components(separatedBy: "payload_json").count - 1
            let parsed = query.components(separatedBy: "json_extract(payload_json").count - 1
                + query.components(separatedBy: "json_valid(payload_json").count - 1
            #expect(selected == parsed, "payload_json returned in \(query)")
            let paths = query.components(separatedBy: "json_extract(payload_json, '").dropFirst().map { $0.prefix { $0 != "'" } }
            #expect(paths.allSatisfy { ["$.settledOverride", "$.settledAt"].contains(String($0)) }, "\(paths)")
        }
    }
}
