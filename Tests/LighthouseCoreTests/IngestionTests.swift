import Foundation
import Testing
@testable import LighthouseCore

/// SPEC §3.1 ingestion: append, partial line, truncation, inode change, over-long lines, per-pass bound.
@Suite struct IngestionTests {
    struct Lines: Codable, Sendable { var seen: [String] = [] }

    func checkpoint(_ path: String) -> FileCheckpoint<Lines> {
        FileCheckpoint(path: path, device: 0, inode: 0, size: 0, offset: 0, mtime: 0, skippedLines: 0, skippingLine: false, state: Lines())
    }

    func advance(_ c: inout FileCheckpoint<Lines>, limits: IngestLimits = .standard) -> ReadOutcome {
        let access = ReadOnlyFileSystem()
        return JSONLTail.advance(&c, stat: access.stat(c.path)!, access: access, limits: limits, now: Date(),
                                 reset: { $0 = Lines() }, handle: { line, s in s.seen.append(String(decoding: line, as: UTF8.self)) })
    }

    @Test func appendReadsOnlyNewBytes() {
        let s = Scratch()
        let p = s.write("a.jsonl", "one\ntwo\n")
        var c = checkpoint(p)
        _ = advance(&c)
        #expect(c.state.seen == ["one", "two"])
        s.append("a.jsonl", "three\n")
        let out = advance(&c)
        #expect(out.bytesRead == 6)
        #expect(c.state.seen == ["one", "two", "three"])
    }

    @Test func partialTrailingLineIsDeferred() {
        let s = Scratch()
        let p = s.write("a.jsonl", "one\ntw")
        var c = checkpoint(p)
        _ = advance(&c)
        #expect(c.state.seen == ["one"])
        #expect(c.offset == 4)
        s.append("a.jsonl", "o\n")
        _ = advance(&c)
        #expect(c.state.seen == ["one", "two"])
    }

    @Test func truncationReindexesFromZero() {
        let s = Scratch()
        let p = s.write("a.jsonl", "one\ntwo\nthree\n")
        var c = checkpoint(p)
        _ = advance(&c)
        let fd = open(p, O_WRONLY | O_TRUNC); close(fd)
        s.append("a.jsonl", "new\n")
        let out = advance(&c)
        #expect(out.reset)
        #expect(c.state.seen == ["new"])
    }

    @Test func inodeChangeReindexes() {
        let s = Scratch()
        let p = s.write("a.jsonl", "one\ntwo\n")
        var c = checkpoint(p)
        _ = advance(&c)
        try! FileManager.default.removeItem(atPath: p)
        s.write("a.jsonl", "alpha\nbeta\ngamma\n")
        let out = advance(&c)
        #expect(out.reset)
        #expect(c.state.seen == ["alpha", "beta", "gamma"])
    }

    @Test func overLongLineIsSkippedAndCounted() {
        let s = Scratch()
        let long = String(repeating: "x", count: 300)
        let p = s.write("a.jsonl", "one\n\(long)\ntwo\n")
        var c = checkpoint(p)
        _ = advance(&c, limits: IngestLimits(maxBytesPerPass: 4 << 20, maxLineBytes: 100))
        #expect(c.state.seen == ["one", "two"])
        #expect(c.skippedLines == 1)
    }

    @Test func overLongLineSpanningPassesIsSkippedOnce() {
        let s = Scratch()
        let long = String(repeating: "x", count: 250)
        let p = s.write("a.jsonl", "\(long)\ntwo\n")
        var c = checkpoint(p)
        let limits = IngestLimits(maxBytesPerPass: 64, maxLineBytes: 32)
        var passes = 0
        repeat { _ = advance(&c, limits: limits); passes += 1 } while !c.isCaughtUp && passes < 20
        #expect(c.state.seen == ["two"])
        #expect(c.skippedLines == 1)
    }

    @Test func eachPassReadsAtMostTheBound() {
        let s = Scratch()
        let p = s.write("a.jsonl", (0..<100).map { "line-\($0)" }.joined(separator: "\n") + "\n")
        var c = checkpoint(p)
        let limits = IngestLimits(maxBytesPerPass: 50, maxLineBytes: 40)
        var passes = 0
        repeat {
            let out = advance(&c, limits: limits)
            #expect(out.bytesRead <= 50)
            passes += 1
        } while !c.isCaughtUp && passes < 1000
        #expect(c.state.seen.count == 100)
        #expect(passes > 10)
    }

    @Test func filesOutsideWindowAreListedNotIndexed() async {
        let s = Scratch()
        let old = s.write("claude/-p/44444444-4444-4444-8444-444444444444.jsonl",
                          #"{"cwd":"/x","sessionId":"44444444-4444-4444-8444-444444444444","type":"user","timestamp":"2026-01-01T10:00:00.000Z"}"# + "\n")
        let past = Date().addingTimeInterval(-40 * 24 * 3600)
        try! FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: old)
        let result = await ClaudeCodeCollector(root: s.claudeRoot).pass(now: Date())
        #expect(result.threads.isEmpty)
        #expect(result.status.filesNotIndexed == 1)
        #expect(result.status.filesInWindow == 0)
    }
}

/// SPEC §11 M1 (4): restart keeps pins, bindings, checkpoints; no full re-read.
@Suite struct RestartTests {
    @Test func restartKeepsPrefsAndCheckpointsWithoutRereading() async throws {
        let s = Scratch()
        s.installFixtures()
        let dbURL = s.url.appendingPathComponent("store/lighthouse.sqlite")
        let store = try Store(url: dbURL)
        let first = Engine(collectors: [ClaudeCodeCollector(root: s.claudeRoot, store: store), CodexCollector(codexHome: s.codexHome, store: store)],
                           store: store, home: s.path)
        let firstSnap = await first.indexToCompletion()
        let firstBytes = await first.bytesReadTotal
        #expect(firstBytes > 0)
        try store.savePrefs(ProjectPrefs(pinned: ["/Users/me/Projects/beta", "/Users/me/Projects/alpha"], paused: ["/p"], archived: ["/a"]))
        try store.saveBinding(ProjectBinding(folder: "/Users/me/Projects/gamma", projectRoot: "/Users/me/Projects/beta"))

        // Restart: a new store connection and new collectors over the same database.
        let reopened = try Store(url: dbURL)
        let second = Engine(collectors: [ClaudeCodeCollector(root: s.claudeRoot, store: reopened), CodexCollector(codexHome: s.codexHome, store: reopened)],
                            store: reopened, home: s.path)
        let snap = await second.pass()
        #expect(await second.bytesReadTotal == 0)
        #expect(snap.projects.flatMap(\.threads).count == firstSnap.projects.flatMap(\.threads).count)
        let prefs = try reopened.loadPrefs()
        #expect(prefs.pinned == ["/Users/me/Projects/beta", "/Users/me/Projects/alpha"])
        #expect(prefs.paused == ["/p"])
        #expect(prefs.archived == ["/a"])
        #expect(try reopened.loadBindings() == [ProjectBinding(folder: "/Users/me/Projects/gamma", projectRoot: "/Users/me/Projects/beta")])
        // The binding is applied: the gamma thread now belongs to beta.
        let beta = snap.projects.first { $0.identity.root == "/Users/me/Projects/beta" }
        #expect(beta?.threads.contains { $0.sessionId == Fixture.codexT3 } == true)

        // Appending after restart reads only the appended bytes.
        let line = #"{"timestamp":"2026-10-29T10:10:00.000Z","ordinal":10,"type":"event_msg","payload":{"type":"task_started"}}"# + "\n"
        s.append("codex/sessions/2026/10/29/rollout-2026-10-29T10-00-00-\(Fixture.codexParent).jsonl", line)
        _ = await second.pass()
        #expect(await second.bytesReadTotal == line.utf8.count)
    }
}
