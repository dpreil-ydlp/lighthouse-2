import Darwin
import Foundation
import Testing
@testable import LighthouseCore

/// Regression tests for Sol M1 review round 1 (docs/reviews/sol-m1-review.md).
@Suite struct RoundOneTests {
    let t1 = Fixture.date("2026-10-29T10:01:00.000Z")

    func userRecord(_ id: String, at iso: String) -> String {
        #"{"cwd":"/Users/me/Projects/alpha","sessionId":"\#(id)","type":"user","message":{"role":"user","content":"x"},"timestamp":"\#(iso)"}"# + "\n"
    }

    // MARK: M1-02 unreadable source must not look fresh

    @Test func claudeUnreadableFileIsUnknownWithLastGoodReadThenRecovers() async {
        let s = Scratch()
        let id = "66666666-6666-4666-8666-666666666666"
        let path = s.write("claude/-p/\(id).jsonl", userRecord(id, at: "2026-10-29T10:00:00.000Z"))
        let collector = ClaudeCodeCollector(root: s.claudeRoot)

        let ok = await collector.pass(now: t1)
        #expect(ok.threads.first?.state == .running)
        #expect(ok.threads.first?.sourceReadAt == t1)
        #expect(ok.status.error == nil)

        // Append, then deny reads (real permission change).
        s.append("claude/-p/\(id).jsonl", userRecord(id, at: "2026-10-29T10:01:30.000Z"))
        chmod(path, 0)
        defer { chmod(path, 0o644) }
        let t2 = t1.addingTimeInterval(60)
        let failed = await collector.pass(now: t2)
        #expect(failed.threads.first?.state == .unknown)
        #expect(failed.threads.first?.sourceReadAt == t1)
        #expect(failed.status.error?.contains("unreadable") == true)
        #expect(failed.status.filesIndexed == 0)

        chmod(path, 0o644)
        let t3 = t1.addingTimeInterval(120)
        let recovered = await collector.pass(now: t3)
        #expect(recovered.threads.first?.state == .running)
        #expect(recovered.threads.first?.sourceReadAt == t3)
        #expect(recovered.threads.first?.lastActivityAt == Fixture.date("2026-10-29T10:01:30.000Z"))
        #expect(recovered.status.error == nil)
        #expect(recovered.status.filesIndexed == 1)
    }

    @Test func codexUnreadableFileIsUnknownWithLastGoodReadThenRecovers() async {
        let s = Scratch()
        let rel = "codex/sessions/2026/10/29/rollout-r.jsonl"
        s.write(rel, #"{"timestamp":"2026-10-29T10:00:00.000Z","ordinal":0,"type":"session_meta","payload":{"id":"r1","cwd":"/x"}}"# + "\n" +
                     #"{"timestamp":"2026-10-29T10:00:01.000Z","ordinal":1,"type":"event_msg","payload":{"type":"task_started"}}"# + "\n")
        let access = RecordingAccess()
        let collector = CodexCollector(codexHome: s.codexHome, access: access)

        let ok = await collector.pass(now: t1)
        #expect(ok.threads.first?.state == .running)
        #expect(ok.threads.first?.sourceReadAt == t1)

        // Failure without any content change: the readability check must catch it.
        access.deny(s.path + "/" + rel)
        let t2 = t1.addingTimeInterval(60)
        let failed = await collector.pass(now: t2)
        #expect(failed.threads.first?.state == .unknown)
        #expect(failed.threads.first?.sourceReadAt == t1)
        #expect(failed.status.error?.contains("unreadable") == true)

        access.allowAll()
        s.append(rel, #"{"timestamp":"2026-10-29T10:02:00.000Z","ordinal":2,"type":"event_msg","payload":{"type":"task_complete"}}"# + "\n")
        let t3 = t1.addingTimeInterval(120)
        let recovered = await collector.pass(now: t3)
        #expect(recovered.threads.first?.state == .idle)
        #expect(recovered.threads.first?.sourceReadAt == t3)
        #expect(recovered.status.error == nil)
    }

    @Test func readStatusSurvivesRestart() async throws {
        let s = Scratch()
        let id = "77777777-7777-4777-8777-777777777777"
        let path = s.write("claude/-p/\(id).jsonl", userRecord(id, at: "2026-10-29T10:00:00.000Z"))
        let store = try Store(url: s.url.appendingPathComponent("db/l.sqlite"))
        _ = await ClaudeCodeCollector(root: s.claudeRoot, store: store).pass(now: t1)
        s.append("claude/-p/\(id).jsonl", userRecord(id, at: "2026-10-29T10:01:30.000Z"))
        chmod(path, 0)
        defer { chmod(path, 0o644) }
        _ = await ClaudeCodeCollector(root: s.claudeRoot, store: store).pass(now: t1.addingTimeInterval(60))
        let saved = try #require(store.loadCheckpoints(source: .claudeCode)[path])
        #expect(saved.readError != nil)
        #expect(saved.lastReadAt == t1.timeIntervalSince1970)
    }

    // MARK: M1-03 no age-based stopped; display-only collapse after 48 h

    @Test func oldThreadsCollapseForDisplayWithoutChangingState() {
        let now = Fixture.date("2026-10-29T12:00:00.000Z")
        func thread(_ id: String, _ state: ThreadState, hoursAgo: Double) -> SessionThread {
            SessionThread(id: id, owningApp: .codex, providerIdentities: [ProviderIdentity(provider: .codex, nativeId: id)],
                          cwd: "/x", state: state, sourceReadAt: now, lastActivityAt: now.addingTimeInterval(-hoursAgo * 3600))
        }
        let oldCompleted = thread("done", .idle, hoursAgo: 72)
        let oldOpen = thread("open", .running, hoursAgo: 72)
        let oldUnknown = thread("unanswered", .unknown, hoursAgo: 72)
        let recentIdle = thread("recent", .idle, hoursAgo: 47)
        let split = ThreadDisplay.split([oldCompleted, oldOpen, oldUnknown, recentIdle], now: now)
        #expect(split.current.map(\.id) == ["open", "recent"])
        #expect(split.earlier.map(\.id) == ["done", "unanswered"])
        #expect(split.earlier.map(\.state) == [.idle, .unknown])
    }

    @Test func oldCompletedCodexThreadIsIdleNotStopped() async {
        let s = Scratch()
        s.write("codex/sessions/2026/10/20/rollout-done.jsonl",
                #"{"timestamp":"2026-10-20T09:00:00.000Z","ordinal":0,"type":"session_meta","payload":{"id":"done","cwd":"/x"}}"# + "\n" +
                #"{"timestamp":"2026-10-20T09:00:01.000Z","ordinal":1,"type":"event_msg","payload":{"type":"task_started"}}"# + "\n" +
                #"{"timestamp":"2026-10-20T09:05:00.000Z","ordinal":2,"type":"event_msg","payload":{"type":"task_complete"}}"# + "\n")
        let now = Fixture.date("2026-10-29T10:00:00.000Z")
        let result = await CodexCollector(codexHome: s.codexHome).pass(now: now)
        let thread = try! #require(result.threads.first)
        #expect(thread.state == .idle)
        #expect(ThreadDisplay.split([thread], now: now).earlier.count == 1)
    }

    // MARK: M1-04 no symlinked roots, ancestors, or swapped directories

    @Test func symlinkedRootIsNotRead() async throws {
        let s = Scratch()
        let id = "88888888-8888-4888-8888-888888888888"
        s.write("elsewhere/projects/-p/\(id).jsonl", userRecord(id, at: "2026-10-29T10:00:00.000Z"))
        try FileManager.default.createSymbolicLink(atPath: s.path + "/claude", withDestinationPath: s.path + "/elsewhere/projects")
        let access = RecordingAccess()
        let result = await ClaudeCodeCollector(root: s.claudeRoot, access: access).pass(now: t1)
        #expect(result.threads.isEmpty)
        #expect(result.bytesRead == 0)
        #expect(result.status.error?.contains("symbolic link") == true)
        #expect(!access.operations.contains { $0.op == "read" || $0.op == "list" || $0.op == "scan" })
    }

    @Test func symlinkedAncestorIsNotRead() async throws {
        let s = Scratch()
        s.write("real/codex/sessions/2026/10/29/rollout-a.jsonl",
                #"{"timestamp":"2026-10-29T10:00:00.000Z","ordinal":0,"type":"session_meta","payload":{"id":"a1","cwd":"/x"}}"# + "\n")
        try FileManager.default.createSymbolicLink(atPath: s.path + "/link", withDestinationPath: s.path + "/real")
        let result = await CodexCollector(codexHome: s.path + "/link/codex").pass(now: t1)
        #expect(result.threads.isEmpty)
        #expect(result.bytesRead == 0)
        #expect(result.status.error?.contains("symbolic link") == true)
        // The boundary rejects the path directly too.
        let fs = ReadOnlyFileSystem()
        #expect(fs.read(s.path + "/link/codex/sessions/2026/10/29/rollout-a.jsonl", offset: 0, count: 10) == nil)
        #expect(fs.stat(s.path + "/link/codex/sessions/2026/10/29/rollout-a.jsonl") == nil)
        #expect(fs.read(s.path + "/real/codex/sessions/2026/10/29/rollout-a.jsonl", offset: 0, count: 10) != nil)
    }

    @Test func intermediateDirectorySwappedForLinkCannotRedirectReads() async throws {
        let s = Scratch()
        let rel = "codex/sessions/2026/10/29/rollout-s.jsonl"
        s.write(rel, #"{"timestamp":"2026-10-29T10:00:00.000Z","ordinal":0,"type":"session_meta","payload":{"id":"s1","cwd":"/x"}}"# + "\n")
        let collector = CodexCollector(codexHome: s.codexHome)
        let first = await collector.pass(now: t1)
        #expect(first.threads.map(\.sessionId) == ["s1"])

        // Swap `10` for a link to a look-alike tree with more bytes in the same file name.
        let fm = FileManager.default
        let dir10 = s.codexHome + "/sessions/2026/10"
        try fm.moveItem(atPath: dir10, toPath: s.path + "/decoy")
        s.append("../" + (s.path as NSString).lastPathComponent + "/decoy/29/rollout-s.jsonl",
                 #"{"timestamp":"2026-10-29T10:05:00.000Z","ordinal":1,"type":"event_msg","payload":{"type":"task_started"}}"# + "\n")
        try fm.createSymbolicLink(atPath: dir10, withDestinationPath: s.path + "/decoy")

        let touched = await collector.pass(now: t1.addingTimeInterval(30), scope: .paths([s.path + "/" + rel]))
        #expect(touched.bytesRead == 0)
        let full = await collector.pass(now: t1.addingTimeInterval(60))
        #expect(full.bytesRead == 0)
        #expect(!full.threads.contains { $0.state == .running })
        #expect(full.status.filesNotIndexed >= 1)
    }
}
