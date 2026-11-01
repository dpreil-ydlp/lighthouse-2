import Foundation
import Testing
@testable import LighthouseCore

@Suite struct ClaudeCollectorTests {
    let now = Fixture.date("2026-10-29T10:06:00.000Z")

    @Test func parsesSessionMetadataFromFixture() async {
        let s = Scratch()
        s.installFixtures()
        let collector = ClaudeCodeCollector(root: s.claudeRoot)
        let result = await collector.pass(now: now)
        #expect(result.threads.count == 2)
        let t = try! #require(result.threads.first { $0.sessionId == Fixture.claudeSession })
        #expect(t.id == "claude:\(Fixture.claudeSession)")
        #expect(t.owningApp == .claudeCode)
        #expect(t.providerIdentities == [ProviderIdentity(provider: .claude, nativeId: Fixture.claudeSession)])
        #expect(t.cwd == "/Users/me/Projects/alpha")
        #expect(t.title == "Parser refactor")
        #expect(t.gitBranch == "main")
        #expect(t.originator == "cli")
        #expect(t.startedAt == Fixture.date("2026-10-29T10:00:01.000Z"))
        #expect(t.lastActivityAt == Fixture.date("2026-10-29T10:05:00.000Z"))
        #expect(t.lastProgressAt == Fixture.date("2026-10-29T10:05:00.000Z"))
        // msg_A appears on two records and counts once: 115 + msg_B 100.
        #expect(t.tokensTotal == 215)
        // Last assistant record has stop_reason end_turn.
        #expect(t.state == .idle)
        #expect(result.status.filesIndexed == 3)
    }

    @Test func subagentFilesAttachAsChildrenNeverParents() async {
        let s = Scratch()
        s.installFixtures()
        let result = await ClaudeCodeCollector(root: s.claudeRoot).pass(now: now)
        #expect(!result.threads.contains { $0.sessionId == "abc123" || $0.title == "test-runner" })
        let parent = try! #require(result.threads.first { $0.sessionId == Fixture.claudeSession })
        #expect(parent.subagents.count == 1)
        let child = parent.subagents[0]
        #expect(child.id == "abc123")
        #expect(child.name == "test-runner")
        #expect(child.model == "haiku")
        #expect(child.provider == .claude)
        #expect(child.state == .idle)
    }

    @Test func titleFromSummaryRecordAndFallback() async {
        let s = Scratch()
        s.installFixtures()
        let result = await ClaudeCodeCollector(root: s.claudeRoot).pass(now: now)
        let second = try! #require(result.threads.first { $0.sessionId == Fixture.claudeSecond })
        #expect(second.title == "Summary title from record")

        var untitled = second
        untitled.title = nil
        #expect(untitled.displayTitle.hasPrefix("Claude Code session · Oct 28"))
        #expect(!untitled.displayTitle.contains(Fixture.bodyCanary))
    }

    @Test func stateRulesFollowSpec22() {
        let t0 = Fixture.date("2026-10-29T10:00:00.000Z")
        func state(_ kind: ClaudeTurnKind?, ageMinutes: Double) -> ThreadState {
            StateRules.claude(lastTurnKind: kind, lastTurnRecordAt: t0.addingTimeInterval(-ageMinutes * 60), sourceReadAt: t0, now: t0)
        }
        #expect(state(.userOrToolResult, ageMinutes: 3) == .running)
        #expect(state(.userOrToolResult, ageMinutes: 11) == .unknown)
        #expect(state(.assistantEndTurn, ageMinutes: 60) == .idle)
        #expect(state(.assistantOther, ageMinutes: 1) == .unknown)
        #expect(state(nil, ageMinutes: 1) == .unknown)
        // Stale source read → unknown, never running.
        #expect(StateRules.claude(lastTurnKind: .userOrToolResult, lastTurnRecordAt: t0,
                                  sourceReadAt: t0.addingTimeInterval(-6 * 60), now: t0) == .unknown)
    }

    /// M1-03: age never invents `stopped`. Old unanswered → unknown; old completed → idle.
    @Test func oldClaudeRecordsKeepEvidenceState() {
        let now = Fixture.date("2026-10-29T10:00:00.000Z")
        let old = now.addingTimeInterval(-30 * 24 * 3600)
        #expect(StateRules.claude(lastTurnKind: .userOrToolResult, lastTurnRecordAt: old, sourceReadAt: now, now: now) == .unknown)
        #expect(StateRules.claude(lastTurnKind: .assistantEndTurn, lastTurnRecordAt: old, sourceReadAt: now, now: now) == .idle)
    }

    @Test func recursiveDiscoveryFindsNestedSessions() async {
        let s = Scratch()
        s.write("claude/-a/nested/deeper/33333333-3333-4333-8333-333333333333.jsonl",
                #"{"cwd":"/x","sessionId":"33333333-3333-4333-8333-333333333333","type":"user","message":{"role":"user","content":"hi"},"timestamp":"2026-10-29T10:00:00.000Z"}"# + "\n")
        let result = await ClaudeCodeCollector(root: s.claudeRoot).pass(now: now)
        #expect(result.threads.map(\.sessionId) == ["33333333-3333-4333-8333-333333333333"])
    }
}

@Suite struct CodexCollectorTests {
    let now = Fixture.date("2026-10-29T10:06:00.000Z")

    @Test func parsesRolloutsAndTitlesFromIndex() async {
        let s = Scratch()
        s.installFixtures()
        let result = await CodexCollector(codexHome: s.codexHome).pass(now: now)
        #expect(result.threads.count == 2)
        let p = try! #require(result.threads.first { $0.sessionId == Fixture.codexParent })
        #expect(p.id == "codex:\(Fixture.codexParent)")
        #expect(p.owningApp == .codex)
        #expect(p.title == "Beta parent thread")
        #expect(p.cwd == "/Users/me/Projects/beta")
        #expect(p.repositoryURL == "git@github.com:me/beta.git")
        #expect(p.originator == "Codex Desktop")
        #expect(p.state == .idle)
        #expect(p.lastActivityAt == Fixture.date("2026-10-29T10:00:09.000Z"))
        #expect(p.lastProgressAt == Fixture.date("2026-10-29T10:00:09.000Z"))
        // Cumulative totals 1000, 1000 (unchanged adds zero), 1500 → 1500.
        #expect(p.tokensTotal == 1500)
    }

    @Test func childSessionAttachesToParent() async {
        let s = Scratch()
        s.installFixtures()
        let result = await CodexCollector(codexHome: s.codexHome).pass(now: now)
        #expect(!result.threads.contains { $0.sessionId == Fixture.codexChild })
        let p = try! #require(result.threads.first { $0.sessionId == Fixture.codexParent })
        #expect(p.subagents.map(\.id) == [Fixture.codexChild])
        #expect(p.subagents[0].name == "coder")
        #expect(p.subagents[0].provider == .codex)
        #expect(p.subagents[0].state == .running)
    }

    @Test func t3OriginatorIsOwnedByT3() async {
        let s = Scratch()
        s.installFixtures()
        let result = await CodexCollector(codexHome: s.codexHome).pass(now: now)
        let t = try! #require(result.threads.first { $0.sessionId == Fixture.codexT3 })
        #expect(t.owningApp == .t3)
        #expect(t.title == "Gamma via T3")
        #expect(t.state == .running)
    }

    @Test func tokenTotalsUseCumulativeDeltasWithEpochs() {
        var s = CodexFileState()
        #expect(CodexCollector.applyTotal(100, to: &s, fromStart: true) == 100)
        #expect(CodexCollector.applyTotal(100, to: &s, fromStart: true) == 0)
        #expect(CodexCollector.applyTotal(250, to: &s, fromStart: true) == 150)
        #expect(CodexCollector.applyTotal(40, to: &s, fromStart: true) == 40)
        #expect(s.tokens == 290)
        #expect(s.tokenEpochs == 1)

        var mid = CodexFileState()
        #expect(CodexCollector.applyTotal(5000, to: &mid, fromStart: false) == 0)
        #expect(mid.tokensPartial)
        #expect(CodexCollector.applyTotal(5100, to: &mid, fromStart: false) == 100)
    }

    @Test func unchangedTotalIsNotProgress() {
        var s = CodexFileState()
        CodexCollector.apply(Data(#"{"timestamp":"2026-10-29T10:00:04.000Z","ordinal":4,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":10}}}}"#.utf8), to: &s)
        #expect(s.lastProgressAt == Fixture.date("2026-10-29T10:00:04.000Z"))
        CodexCollector.apply(Data(#"{"timestamp":"2026-10-29T10:00:09.000Z","ordinal":5,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":10}}}}"#.utf8), to: &s)
        #expect(s.lastProgressAt == Fixture.date("2026-10-29T10:00:04.000Z"))
        #expect(s.lastActivityAt == Fixture.date("2026-10-29T10:00:09.000Z"))
    }

    @Test func codexStateRules() {
        let t0 = Fixture.date("2026-10-29T10:00:00.000Z")
        #expect(StateRules.codex(turnOpen: true, sourceReadAt: t0, now: t0) == .running)
        #expect(StateRules.codex(turnOpen: false, sourceReadAt: t0, now: t0) == .idle)
        #expect(StateRules.codex(turnOpen: nil, sourceReadAt: t0, now: t0) == .unknown)
        #expect(StateRules.codex(turnOpen: true, sourceReadAt: t0.addingTimeInterval(-6 * 60), now: t0) == .unknown)
    }

    /// M1-03: an open Codex task 25 h old, freshly read, stays running (no age-based stopped).
    @Test func oldOpenCodexTaskStaysRunning() async {
        let s = Scratch()
        s.write("codex/sessions/2026/10/28/rollout-old.jsonl",
                #"{"timestamp":"2026-10-27T09:00:00.000Z","ordinal":0,"type":"session_meta","payload":{"id":"old-open","cwd":"/x"}}"# + "\n" +
                #"{"timestamp":"2026-10-27T09:00:01.000Z","ordinal":1,"type":"event_msg","payload":{"type":"task_started"}}"# + "\n")
        let now = Fixture.date("2026-10-28T10:00:01.000Z")
        let result = await CodexCollector(codexHome: s.codexHome).pass(now: now)
        #expect(result.threads.first { $0.sessionId == "old-open" }?.state == .running)
    }

    @Test func microsecondTimestampsParse() {
        #expect(Timestamps.parse("2026-03-05T21:03:40.980783Z") != nil)
        #expect(Timestamps.parse("2026-10-29T10:00:00Z") == Fixture.date("2026-10-29T10:00:00.000Z"))
    }

    /// M7: the arithmetic UTC parser gives exactly what `timegm` gave, including the fields it
    /// normalizes (month 00 or 13, day 00 or 31 in a short month, hour 24, second 60). Years before
    /// 1901 are left out: there macOS `timegm` overflows its 32-bit range, and no source writes them.
    @Test func utcParserMatchesTimegm() {
        func timegmValue(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> Double {
            var t = tm(tm_sec: Int32(s), tm_min: Int32(mi), tm_hour: Int32(h), tm_mday: Int32(d), tm_mon: Int32(mo - 1), tm_year: Int32(y - 1900),
                       tm_wday: 0, tm_yday: 0, tm_isdst: 0, tm_gmtoff: 0, tm_zone: nil)
            return Double(timegm(&t))
        }
        var cases: [(Int, Int, Int, Int, Int, Int)] = []
        for y in [1969, 1970, 1999, 2000, 2024, 2025, 2026, 2100, 2400, 9999] {
            for mo in [0, 1, 2, 3, 6, 11, 12, 13, 25, 99] {
                for d in [0, 1, 28, 29, 30, 31, 99] { cases.append((y, mo, d, 0, 0, 0)) }
            }
        }
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<5000 {
            cases.append((Int.random(in: 1970...2100, using: &generator), Int.random(in: 0...99, using: &generator), Int.random(in: 0...99, using: &generator),
                          Int.random(in: 0...99, using: &generator), Int.random(in: 0...99, using: &generator), Int.random(in: 0...99, using: &generator)))
        }
        for (y, mo, d, h, mi, s) in cases {
            let text = String(format: "%04d-%02d-%02dT%02d:%02d:%02d.25Z", y, mo, d, h, mi, s)
            #expect(Timestamps.parse(text)?.timeIntervalSince1970 == timegmValue(y, mo, d, h, mi, s) + 0.25, "\(text)")
        }
    }
}
