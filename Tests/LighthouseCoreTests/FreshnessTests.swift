import Foundation
import Testing
@testable import LighthouseCore

/// M7 C6: the footprint changes keep every delay from new source data to the shelf. Each test drives
/// the engine the way the app's live loop does: a pass for the paths FSEvents reported (the loop runs
/// it at most 10 s after the event), a full rescan every 60 s for dropped events, and T3 polled at
/// most once per `T3Collector.defaultMinInterval`. The same tests pass on the pre-M7 code (receipt).
@Suite struct FreshnessTests {
    func at(_ time: String) -> Date { Fixture.date("2026-11-01T\(time).000Z") }

    static let codexFile = "codex/sessions/2026/11/01/rollout-2026-11-01T09-00-00-c-fresh.jsonl"
    static func codexLine(_ type: String, _ time: String) -> String {
        #"{"timestamp":"2026-11-01T\#(time).000Z","type":"event_msg","payload":{"type":"\#(type)"}}"# + "\n"
    }

    static let claudeFile = "claude/-Users-me-Projects-fresh/33333333-3333-4333-8333-333333333333.jsonl"
    static func claudeLine(_ type: String, _ time: String, stop: String? = nil) -> String {
        let message = stop.map { #","message":{"id":"m-\#(time)","stop_reason":"\#($0)"}"# } ?? ""
        return #"{"cwd":"/Users/me/Projects/fresh","sessionId":"33333333-3333-4333-8333-333333333333","type":"\#(type)"\#(message),"timestamp":"2026-11-01T\#(time).000Z"}"# + "\n"
    }

    func codexThread(_ snapshot: Snapshot) -> SessionThread? { snapshot.projects.flatMap(\.threads).first { $0.sessionId == "c-fresh" } }
    func claudeThread(_ snapshot: Snapshot) -> SessionThread? {
        snapshot.projects.flatMap(\.threads).first { $0.sessionId == "33333333-3333-4333-8333-333333333333" }
    }

    func codexScratch() -> (Scratch, Engine) {
        let s = Scratch()
        let cwd = s.dir("Projects/fresh")
        s.write(Self.codexFile, #"{"timestamp":"2026-11-01T09:00:00.000Z","type":"session_meta","payload":{"id":"c-fresh","cwd":"\#(cwd)"}}"# + "\n"
                + Self.codexLine("task_started", "09:00:01"))
        return (s, Engine(collectors: [CodexCollector(codexHome: s.codexHome)], store: nil, home: s.path))
    }

    func claudeScratch() -> (Scratch, Engine) {
        let s = Scratch()
        s.write(Self.claudeFile, Self.claudeLine("user", "09:00:00"))
        return (s, Engine(collectors: [ClaudeCodeCollector(root: s.claudeRoot)], store: nil, home: s.path))
    }

    @Test func newCodexLineShowsOnThePassForItsEvent() async throws {
        let (s, engine) = codexScratch()
        var snapshot = await engine.pass(now: at("09:01:00"))
        #expect(codexThread(snapshot)?.state == .running)
        s.append(Self.codexFile, Self.codexLine("task_complete", "09:02:00"))
        snapshot = await engine.pass(now: at("09:02:10"), scope: .paths([s.path + "/" + Self.codexFile]))
        let thread = try #require(codexThread(snapshot))
        #expect(thread.lastActivityAt == at("09:02:00"))
        #expect(thread.state != .running)
    }

    @Test func codexLineWithoutAnEventShowsOnTheNextFullRescan() async throws {
        let (s, engine) = codexScratch()
        _ = await engine.pass(now: at("09:01:00"))
        s.append(Self.codexFile, Self.codexLine("task_complete", "09:02:00"))
        var snapshot = await engine.pass(now: at("09:02:10"), scope: .paths([]))
        #expect(codexThread(snapshot)?.lastActivityAt == at("09:00:01"))
        snapshot = await engine.pass(now: at("09:03:00"), scope: .full)
        #expect(codexThread(snapshot)?.lastActivityAt == at("09:02:00"))
        #expect(codexThread(snapshot)?.state != .running)
    }

    @Test func newClaudeLineShowsOnThePassForItsEvent() async throws {
        let (s, engine) = claudeScratch()
        var snapshot = await engine.pass(now: at("09:01:00"))
        #expect(claudeThread(snapshot)?.lastActivityAt == at("09:00:00"))
        s.append(Self.claudeFile, Self.claudeLine("assistant", "09:02:00", stop: "end_turn"))
        snapshot = await engine.pass(now: at("09:02:10"), scope: .paths([s.path + "/" + Self.claudeFile]))
        #expect(claudeThread(snapshot)?.lastActivityAt == at("09:02:00"))
    }

    @Test func claudeLineWithoutAnEventShowsOnTheNextFullRescan() async throws {
        let (s, engine) = claudeScratch()
        _ = await engine.pass(now: at("09:01:00"))
        s.append(Self.claudeFile, Self.claudeLine("assistant", "09:02:00", stop: "end_turn"))
        var snapshot = await engine.pass(now: at("09:02:10"), scope: .paths([]))
        #expect(claudeThread(snapshot)?.lastActivityAt == at("09:00:00"))
        snapshot = await engine.pass(now: at("09:03:00"), scope: .full)
        #expect(claudeThread(snapshot)?.lastActivityAt == at("09:02:00"))
    }

    /// A line longer than one read slice still arrives whole on the pass for its event.
    @Test func lineLongerThanASliceShowsOnThePassForItsEvent() async throws {
        let (s, engine) = codexScratch()
        _ = await engine.pass(now: at("09:01:00"))
        let padding = String(repeating: "x", count: 600 << 10)
        s.append(Self.codexFile, #"{"timestamp":"2026-11-01T09:02:00.000Z","type":"event_msg","payload":{"type":"task_complete","pad":"\#(padding)"}}"# + "\n")
        let snapshot = await engine.pass(now: at("09:02:10"), scope: .paths([s.path + "/" + Self.codexFile]))
        #expect(codexThread(snapshot)?.lastActivityAt == at("09:02:00"))
        #expect(codexThread(snapshot)?.state != .running)
    }

    /// A waiting request shows on the first T3 poll after it: at most 60 s later, as before M7.
    @Test func t3WaitingRequestShowsOnTheFirstPollAfterIt() async throws {
        let s = Scratch()
        let t3 = T3Fixture(s)
        t3.project("p", title: "P", root: s.dir("Projects/p"))
        t3.thread("live", project: "p", title: "Live thread", created: at("09:00:00"))
        t3.run(thread: "live", ordinal: 1, status: "running", requested: at("09:00:00"))
        let engine = Engine(collectors: [], store: nil, home: s.path, t3: T3Collector(reader: T3Reader(t3Home: t3.home)))
        func live(_ snapshot: Snapshot) -> SessionThread? { snapshot.projects.flatMap(\.threads).first { $0.t3ThreadId == "live" } }
        #expect(T3Collector.defaultMinInterval == 60)
        var snapshot = await engine.pass(now: at("09:10:00"))
        #expect(live(snapshot)?.state == .running)
        t3.request("req-1", thread: "live", kind: "command", created: at("09:10:05"))
        snapshot = await engine.pass(now: at("09:10:59"))
        #expect(live(snapshot)?.state == .running)
        snapshot = await engine.pass(now: at("09:11:00"))
        #expect(live(snapshot)?.state == .waitingForOwner)
        #expect(snapshot.projects.first?.attentionItems.map(\.id) == ["waitingForOwner|t3:live|req-1"])
    }
}
