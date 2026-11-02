import Foundation
import Testing
@testable import LighthouseCore

/// M8 thread summaries: contract `docs/contracts/M8-summaries.md` C1, C5, C6 and the no-change part of C7.
/// No test here starts a real `claude` or `codex` process: CLI runs use `FakeLauncher`, and the
/// process-launcher tests run `/bin/cat` and `/bin/sleep`.
@Suite struct SummaryTests {
    static let t0 = Date(timeIntervalSince1970: 1_793_000_000)

    static func candidate(_ id: String = "claude:a", state: ThreadState = .idle, activity: Date, paths: [String] = ["/x.jsonl"]) -> SummaryCandidate {
        SummaryCandidate(threadId: id, title: "Recipe card layout", projectName: "recipe-box", state: state, lastActivityAt: activity,
                         transcriptPaths: paths)
    }

    static func summary(_ id: String = "claude:a", made: Date, activity: Date, hash: String = "h") -> ThreadSummary {
        ThreadSummary(threadId: id, line1: "Fixing contrast", line2: nil, madeAt: made, activityAt: activity, inputHash: hash,
                      provider: .claude, model: SummarySettings.defaultClaudeModel)
    }

    // MARK: Eligibility, trigger, debounce

    @Test func eligibilityIsRunningWaitingOrActiveInTwoHours() {
        let now = Self.t0
        #expect(SummaryRules.isEligible(Self.candidate(state: .running, activity: now.addingTimeInterval(-5 * 3600)), now: now))
        #expect(SummaryRules.isEligible(Self.candidate(state: .waitingForOwner, activity: now.addingTimeInterval(-5 * 3600)), now: now))
        #expect(SummaryRules.isEligible(Self.candidate(state: .idle, activity: now.addingTimeInterval(-7199)), now: now))
        #expect(!SummaryRules.isEligible(Self.candidate(state: .idle, activity: now.addingTimeInterval(-7201)), now: now))
        #expect(!SummaryRules.isEligible(Self.candidate(state: .stopped, activity: now.addingTimeInterval(-3 * 3600)), now: now))
        #expect(!SummaryRules.isEligible(Self.candidate(state: .unknown, activity: now.addingTimeInterval(-3 * 3600)), now: now))
        // An ineligible thread keeps its last summary: it is simply never due.
        let old = Self.candidate(state: .idle, activity: now.addingTimeInterval(-3 * 3600))
        #expect(!SummaryRules.isDue(old, last: Self.summary(made: now.addingTimeInterval(-4 * 3600), activity: now.addingTimeInterval(-4 * 3600)), failure: nil, now: now))
    }

    @Test func changedThreadIsDueOnlyAfterSixtySecondsQuiet() {
        let activity = Self.t0
        let last = Self.summary(made: activity.addingTimeInterval(-300), activity: activity.addingTimeInterval(-400))
        let c = Self.candidate(state: .idle, activity: activity)
        #expect(!SummaryRules.isDue(c, last: last, failure: nil, now: activity.addingTimeInterval(59)))
        #expect(SummaryRules.isDue(c, last: last, failure: nil, now: activity.addingTimeInterval(60)))
        // Never summarized: due once quiet.
        #expect(!SummaryRules.isDue(c, last: nil, failure: nil, now: activity.addingTimeInterval(30)))
        #expect(SummaryRules.isDue(c, last: nil, failure: nil, now: activity.addingTimeInterval(61)))
    }

    @Test func unchangedThreadIsNeverDue() {
        let activity = Self.t0
        let last = Self.summary(made: activity.addingTimeInterval(5), activity: activity)
        for state in [ThreadState.idle, .running, .waitingForOwner] {
            let c = Self.candidate(state: state, activity: activity)
            for later in [60.0, 600, 601, 3600, 7000] {
                #expect(!SummaryRules.isDue(c, last: last, failure: nil, now: activity.addingTimeInterval(later)), "\(state) +\(later)")
            }
        }
    }

    @Test func runningThreadThatKeepsChangingRefreshesAfterTenMinutes() {
        // Activity every few seconds: never quiet for 60 s.
        let made = Self.t0
        let last = Self.summary(made: made, activity: made)
        let at599 = made.addingTimeInterval(599), at600 = made.addingTimeInterval(600)
        #expect(!SummaryRules.isDue(Self.candidate(state: .running, activity: at599.addingTimeInterval(-2)), last: last, failure: nil, now: at599))
        #expect(SummaryRules.isDue(Self.candidate(state: .running, activity: at600.addingTimeInterval(-2)), last: last, failure: nil, now: at600))
        // Not running: the 10 min refresh does not apply; it waits for quiet.
        #expect(!SummaryRules.isDue(Self.candidate(state: .idle, activity: at600.addingTimeInterval(-2)), last: last, failure: nil, now: at600))
        // First summary of a running thread does not wait for quiet.
        #expect(SummaryRules.isDue(Self.candidate(state: .running, activity: made.addingTimeInterval(-1)), last: nil, failure: nil, now: made))
    }

    @Test func threadWithoutTranscriptIsNeverDue() {
        let c = Self.candidate(state: .running, activity: Self.t0, paths: [])
        #expect(!SummaryRules.isDue(c, last: nil, failure: nil, now: Self.t0.addingTimeInterval(3600)))
    }

    @Test func failedThreadWaitsTenMinutesUnlessItChanges() {
        let activity = Self.t0
        let c = Self.candidate(state: .idle, activity: activity)
        let failure = SummaryFailure(activityAt: activity, at: activity.addingTimeInterval(70))
        #expect(!SummaryRules.isDue(c, last: nil, failure: failure, now: activity.addingTimeInterval(600)))
        #expect(SummaryRules.isDue(c, last: nil, failure: failure, now: activity.addingTimeInterval(671)))
        let changed = Self.candidate(state: .idle, activity: activity.addingTimeInterval(100))
        #expect(SummaryRules.isDue(changed, last: nil, failure: failure, now: activity.addingTimeInterval(200)))
    }

    @Test func nextPrefersRunningAndWaitingThenNewest() {
        let now = Self.t0
        let idleNew = Self.candidate("i", state: .idle, activity: now.addingTimeInterval(-61))
        let runningOld = Self.candidate("r", state: .running, activity: now.addingTimeInterval(-3000))
        let waiting = Self.candidate("w", state: .waitingForOwner, activity: now.addingTimeInterval(-2000))
        #expect(SummaryRules.next([idleNew, runningOld, waiting], summaries: [:], failures: [:], now: now)?.threadId == "w")
        #expect(SummaryRules.next([idleNew, runningOld], summaries: [:], failures: [:], now: now)?.threadId == "r")
        #expect(SummaryRules.next([idleNew], summaries: [:], failures: [:], now: now)?.threadId == "i")
    }

    // MARK: Limits through the service

    @Test func singleFlightRunsOneCallAtATime() async throws {
        let h = Harness()
        let launcher = FakeLauncher(gated: true)
        let service = h.service(launcher: launcher)
        let now = Self.t0
        let cands = (0..<3).map { Self.candidate("t\($0)", state: .idle, activity: now.addingTimeInterval(-120)) }
        let first = Task { await service.step(cands, now: now) }
        // Wait until the first call is inside the launcher (held there by the gate).
        while launcher.count == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await service.isBusy)
        // While it runs, further steps start nothing.
        for _ in 0..<5 { #expect(await service.step(cands, now: now) == nil) }
        #expect(launcher.count == 1)
        launcher.open()
        #expect(await first.value?.outcome == .made)
        #expect(launcher.maxConcurrent == 1)
        // Once it is done, the next due thread may run.
        #expect(await service.step(cands, now: now)?.outcome == .made)
        #expect(launcher.count == 2)
    }

    @Test func hourlyCapStopsCallsUntilTheWindowMoves() async {
        let h = Harness()
        let launcher = FakeLauncher()
        let service = h.service(settings: SummarySettings(provider: .claude, hourlyCap: 3), launcher: launcher)
        let start = Self.t0
        var cands = (0..<6).map { Self.candidate("t\($0)", state: .idle, activity: start.addingTimeInterval(-100)) }
        for i in 0..<6 { _ = await service.step(cands, now: start.addingTimeInterval(Double(i))) }
        #expect(launcher.count == 3)
        #expect(await service.callsInLastHour(now: start.addingTimeInterval(10)) == 3)
        // 59 min later still capped; after the first call leaves the hour, one more.
        _ = await service.step(cands, now: start.addingTimeInterval(3599))
        #expect(launcher.count == 3)
        _ = await service.step(cands, now: start.addingTimeInterval(3600.5))
        #expect(launcher.count == 4)
        // The cap persists across restart (calls are stored, not just counted in memory).
        let restarted = h.service(settings: SummarySettings(provider: .claude, hourlyCap: 3), launcher: launcher, now: start.addingTimeInterval(3601))
        cands = cands.map { var c = $0; c.lastActivityAt = start.addingTimeInterval(3540); return c }
        _ = await restarted.step(cands, now: start.addingTimeInterval(3601))
        #expect(launcher.count == 4)
        // The cap can never be set above 30.
        #expect(SummarySettings.clampCap(500) == 30)
        #expect(SummarySettings.clampCap(0) == 1)
    }

    @Test func callTimesOutAfterTheTimeoutAndCountsAsFailed() async {
        let h = Harness()
        let launcher = FakeLauncher(timedOut: true)
        let service = h.service(launcher: launcher)
        let report = await service.step([Self.candidate(state: .idle, activity: Self.t0.addingTimeInterval(-100))], now: Self.t0)
        #expect(report?.outcome == .timedOut)
        #expect(launcher.timeouts == [SummaryRules.callTimeout])
        #expect(await service.all().isEmpty)
        // Not retried at once for the same activity.
        #expect(await service.step([Self.candidate(state: .idle, activity: Self.t0.addingTimeInterval(-100))], now: Self.t0.addingTimeInterval(5)) == nil)
    }

    @Test func realLauncherStopsAProcessAtTheTimeout() async {
        let outcome = await SystemProcessLauncher().run(
            SummaryCommand(executable: "/bin/sleep", arguments: ["30"], environment: [:], directory: "/"), input: Data(), timeout: 0.5)
        #expect(outcome.launched)
        #expect(outcome.timedOut)
        // The launcher's own clock: stopped at the timeout (SIGTERM), not after the 30 s sleep. The
        // test's wall time can be longer when other suites keep the cooperative pool busy.
        #expect(outcome.seconds >= 0.5 && outcome.seconds < 3, "\(outcome.seconds)")
        #expect(outcome.exitCode == SIGTERM)
    }

    @Test func realLauncherSendsInputOnStdinOnly() async {
        let outcome = await SystemProcessLauncher().run(
            SummaryCommand(executable: "/bin/cat", arguments: [], environment: [:], directory: "/"), input: Data("line one\n".utf8), timeout: 5)
        #expect(outcome.exitCode == 0)
        #expect(String(decoding: outcome.stdout, as: UTF8.self) == "line one\n")
        #expect(!outcome.timedOut)
    }

    // MARK: Provider switch and Off

    @Test func providerSwitchChangesCLIArgvAndModel() async {
        let h = Harness()
        let launcher = FakeLauncher()
        let service = h.service(settings: SummarySettings(provider: .claude), launcher: launcher)
        let a = Self.candidate("a", state: .idle, activity: Self.t0.addingTimeInterval(-100))
        let b = Self.candidate("b", state: .idle, activity: Self.t0.addingTimeInterval(-100))
        _ = await service.step([a], now: Self.t0)
        await service.apply(SummarySettings(provider: .chatgpt))
        launcher.stdout = FakeLauncher.codexAnswer
        _ = await service.step([a, b], now: Self.t0.addingTimeInterval(1))
        let commands = launcher.commands
        #expect(commands.count == 2)
        #expect(commands[0].executable.hasSuffix("/claude"))
        #expect(commands[0].arguments.contains("claude-haiku-5-5"))
        #expect(commands[1].executable.hasSuffix("/codex"))
        #expect(commands[1].arguments.starts(with: ["exec", "--ephemeral"]))
        #expect(commands[1].arguments.contains("gpt-6-luna"))
        let all = await service.all()
        #expect(all["a"]?.provider == .claude)
        #expect(all["b"]?.provider == .chatgpt)
        #expect(all["b"]?.model == "gpt-6-luna")
        #expect(all["b"]?.line1 == "Fixing dark mode contrast on recipe cards")
    }

    @Test func offStartsNoProcessAndReadsNoTranscript() async {
        let h = Harness()
        let s = Scratch()
        let path = s.write("claude/p/t.jsonl", Self.claudeTranscript(canary: Fixture.bodyCanary))
        let access = RecordingAccess()
        let launcher = FakeLauncher()
        let service = SummaryService(settings: SummarySettings(), store: h.store, transcripts: FileTranscriptSource(access: access),
                                     launcher: launcher, locator: h.locator, scratch: h.scratch, now: Self.t0)
        let due = Self.candidate(state: .running, activity: Self.t0.addingTimeInterval(-3600), paths: [path])
        for minute in 0..<120 { #expect(await service.step([due], now: Self.t0.addingTimeInterval(Double(minute) * 60)) == nil) }
        #expect(launcher.count == 0)
        #expect(access.operations.isEmpty)
        #expect(await service.launches == 0)
        // Turning it on makes exactly the due call; turning it off again stops at once.
        await service.apply(SummarySettings(provider: .claude))
        #expect(await service.step([due], now: Self.t0.addingTimeInterval(7300))?.outcome == .made)
        await service.apply(SummarySettings(provider: .off))
        let changed = Self.candidate(state: .running, activity: Self.t0.addingTimeInterval(7400), paths: [path])
        #expect(await service.step([changed], now: Self.t0.addingTimeInterval(8100)) == nil)
        #expect(launcher.count == 1)
    }

    @Test func settingsDefaultToOffAndRoundTrip() throws {
        let h = Harness()
        #expect(try h.store.loadSummarySettings() == SummarySettings())
        #expect(SummarySettings().provider == .off)
        #expect(SummarySettings().claudeModel == "claude-haiku-5-5")
        #expect(SummarySettings().chatgptModel == "gpt-6-luna")
        let custom = SummarySettings(provider: .chatgpt, claudeModel: "haiku", chatgptModel: "gpt-6-luna", hourlyCap: 12)
        try h.store.saveSummarySettings(custom)
        #expect(try h.store.loadSummarySettings() == custom)
        // A model id that looks like an option is never used.
        #expect(!SummarySettings.validModel("--dangerously-skip-permissions"))
        #expect(!SummarySettings.validModel("haiku 5"))
        #expect(SummaryCLI.command(provider: .claude, model: "-x", executable: "/c", scratch: "/s", home: "/h") == nil)
    }

    /// A T3-owned thread is summarized from the provider transcript that backs it (T3 stays read-only).
    @Test func t3ThreadCarriesItsProviderTranscript() {
        var t3 = T3State(environmentId: "env")
        t3.projects = [T3State.Project(id: "p", title: "Alpha", root: "/Users/me/Projects/alpha")]
        t3.threads = [T3State.Thread(id: "T1", projectId: "p", title: "Ship it", createdAt: Self.t0, archived: false, worktreePath: nil, lineageParent: nil)]
        t3.providerThreads = [T3State.ProviderThread(threadId: "T1", provider: .codex, nativeId: "X")]
        var session = SessionThread(id: "codex:X", owningApp: .t3, providerIdentities: [ProviderIdentity(provider: .codex, nativeId: "X")],
                                    cwd: "/Users/me/Projects/alpha", state: .idle, sourceReadAt: Self.t0, lastActivityAt: Self.t0)
        session.transcriptPaths = ["/codex/sessions/rollout-X.jsonl"]
        let merged = ThreadMerge.merge(jsonl: [session], t3: t3, readAt: Self.t0, now: Self.t0)
        #expect(merged.count == 1)
        #expect(merged[0].id == "t3:T1")
        #expect(merged[0].transcriptPaths == ["/codex/sessions/rollout-X.jsonl"])
    }

    @Test func collectedThreadsKnowTheirTranscriptFile() async {
        let s = Scratch()
        s.installFixtures()
        let engine = Engine(collectors: [ClaudeCodeCollector(root: s.claudeRoot), CodexCollector(codexHome: s.codexHome)], store: nil, home: s.path)
        let threads = (await engine.indexToCompletion()).projects.flatMap(\.threads)
        #expect(threads.contains { $0.id.hasPrefix("claude:") } && threads.contains { $0.id.hasPrefix("codex:") })
        for thread in threads {
            #expect(thread.transcriptPaths.count == 1, "\(thread.id)")
            #expect(thread.transcriptPaths.allSatisfy { $0.hasSuffix(".jsonl") && FileManager.default.fileExists(atPath: $0) })
            #expect(thread.transcriptPaths.allSatisfy { $0.hasPrefix(s.claudeRoot) || $0.hasPrefix(s.codexHome) })
        }
    }

    @Test func summaryTestHookWorksOnlyInCompleteTestMode() {
        let real = URL(fileURLWithPath: "/Users/me/Library/Application Support/Lighthouse/lighthouse.sqlite")
        let test = ["app", "-LighthouseTestStore", "/private/tmp/s/l.sqlite", "-LighthouseTestClaudeRoot", "/private/tmp/c",
                    "-LighthouseTestCodexHome", "/private/tmp/x"]
        #expect(TestHooks.summaryProvider(arguments: test + ["-LighthouseTestSummaries", "claude"], realStore: real) == .claude)
        #expect(TestHooks.summaryProvider(arguments: test + ["-LighthouseTestSummaries", "chatgpt"], realStore: real) == .chatgpt)
        #expect(TestHooks.summaryProvider(arguments: test + ["-LighthouseTestSummaries", "off"], realStore: real) == nil)
        #expect(TestHooks.summaryProvider(arguments: ["app", "-LighthouseTestSummaries", "claude"], realStore: real) == nil)
    }

    // MARK: Tail extraction and redaction

    static func claudeTranscript(canary: String) -> String {
        let lines: [[String: Any]] = [
            ["type": "user", "message": ["role": "user", "content": "Please show the cook time under the title."], "timestamp": "2026-11-01T09:00:00.000Z"],
            ["type": "assistant", "message": ["role": "assistant", "content": [
                ["type": "thinking", "thinking": "THINKING-SECRET-NOT-SENT"],
                ["type": "text", "text": "I will update RecipeCard. Ref \(canary)."],
                ["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "cat TOOL-INPUT-NOT-SENT"]]]]],
            ["type": "user", "toolUseResult": ["stdout": "x"], "message": ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "t1", "content": "FILE-CONTENT-NOT-SENT"]]]],
            ["type": "user", "isMeta": true, "message": ["role": "user", "content": "META-NOT-SENT"]],
            ["type": "attachment", "attachment": ["content": "ATTACHMENT-NOT-SENT"]],
            ["type": "api-request-blob", "message": ["role": "user", "content": [["type": "text", "text": "BLOB-NOT-SENT"]]]],
            ["type": "last-prompt", "lastPrompt": "LASTPROMPT-NOT-SENT"],
            ["type": "user", "message": ["role": "user", "content": [["type": "text", "text": "<system-reminder>REMINDER-NOT-SENT</system-reminder>Also check dark mode."]]]],
            ["type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": "Key is sk-ant-api03-ABCDEFGHIJKLMNOP and password=hunter2hunter2 done."]]]],
        ]
        return lines.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n") + "\n"
    }

    @Test func claudeTailKeepsUserAndAssistantTextOnly() {
        let s = Scratch()
        let path = s.write("c.jsonl", Self.claudeTranscript(canary: "CANARY-X"))
        let tail = TranscriptTail.read(paths: [path], access: ReadOnlyFileSystem()) ?? ""
        #expect(tail.contains("User: Please show the cook time under the title."))
        #expect(tail.contains("Assistant: I will update RecipeCard. Ref CANARY-X."))
        #expect(tail.contains("User: Also check dark mode."))
        for excluded in ["THINKING-SECRET-NOT-SENT", "TOOL-INPUT-NOT-SENT", "FILE-CONTENT-NOT-SENT", "META-NOT-SENT", "ATTACHMENT-NOT-SENT",
                         "BLOB-NOT-SENT", "LASTPROMPT-NOT-SENT", "REMINDER-NOT-SENT", "sk-ant-api03", "hunter2"] {
            #expect(!tail.contains(excluded), "\(excluded)")
        }
        #expect(tail.contains("[redacted]"))
        // Oldest first.
        #expect(tail.range(of: "cook time")!.lowerBound < tail.range(of: "dark mode")!.lowerBound)
    }

    @Test func codexTailKeepsUserAndAssistantTextOnly() {
        let s = Scratch()
        func line(_ type: String, _ payload: [String: Any]) -> String {
            String(decoding: try! JSONSerialization.data(withJSONObject: ["timestamp": "2026-11-01T09:00:00.000Z", "type": type, "payload": payload]), as: UTF8.self)
        }
        let text = [
            line("session_meta", ["id": "x", "cwd": "/p", "base_instructions": ["text": "BASE-NOT-SENT"]]),
            line("response_item", ["type": "message", "role": "developer", "content": [["type": "input_text", "text": "DEVELOPER-NOT-SENT"]]]),
            line("response_item", ["type": "message", "role": "user", "content": [["type": "input_text", "text": "# AGENTS.md instructions for /p\nAGENTS-NOT-SENT"]]]),
            line("response_item", ["type": "message", "role": "user", "content": [["type": "input_text", "text": "<environment_context>ENV-NOT-SENT</environment_context>"]]]),
            line("response_item", ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Fix the flaky login test."]]]),
            line("response_item", ["type": "reasoning", "summary": [["type": "summary_text", "text": "REASONING-NOT-SENT"]]]),
            line("response_item", ["type": "function_call", "name": "exec_command", "arguments": "{\"cmd\":\"FUNCTION-ARGS-NOT-SENT\"}"]),
            line("response_item", ["type": "function_call_output", "output": "TOOL-OUTPUT-NOT-SENT"]),
            line("response_item", ["type": "custom_tool_call_output", "output": "CUSTOM-OUTPUT-NOT-SENT"]),
            line("event_msg", ["type": "agent_message", "message": "EVENT-DUPLICATE-NOT-SENT"]),
            line("response_item", ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "The test waits on a timer; replacing it with a fake clock."]]]),
        ].joined(separator: "\n") + "\n"
        let path = s.write("r.jsonl", text)
        let tail = TranscriptTail.read(paths: [path], access: ReadOnlyFileSystem()) ?? ""
        #expect(tail == "User: Fix the flaky login test.\n\nAssistant: The test waits on a timer; replacing it with a fake clock.")
    }

    @Test func tailIsTheLast24KBAndReadsABoundedWindow() {
        let s = Scratch()
        var lines: [String] = []
        for i in 0..<400 {
            let text = "message \(i) " + String(repeating: "x", count: 200)
            lines.append(String(decoding: try! JSONSerialization.data(withJSONObject: ["type": i % 2 == 0 ? "user" : "assistant",
                                                                                      "message": ["role": "a", "content": text]]), as: UTF8.self))
        }
        // A huge tool-output line at the start of the file is outside the read window.
        let path = s.write("big.jsonl", "{\"type\":\"user\",\"message\":{\"content\":\"" + String(repeating: "y", count: 3 << 20) + "\"}}\n"
                           + lines.joined(separator: "\n") + "\n")
        let access = RecordingAccess()
        let tail = TranscriptTail.read(paths: [path], access: access) ?? ""
        #expect(tail.utf8.count <= TranscriptTail.maxTextBytes)
        #expect(tail.utf8.count > TranscriptTail.maxTextBytes - 300)
        #expect(tail.hasSuffix("message 399 " + String(repeating: "x", count: 200)))
        #expect(!tail.contains("yyyy"))
        #expect(Set(access.operations.map(\.op)) == ["stat", "read"])
        #expect(access.operations.allSatisfy { $0.path == path })
        // Multi-byte text is cut at a character boundary.
        let cut = TranscriptTail.keepLast("é" + String(repeating: "ü", count: 20), bytes: 9)
        #expect(cut == "üüüü")
    }

    @Test func redactorRemovesKnownSecretPatterns() {
        // Fake values; some are split so secret scanners do not flag the test source.
        let secrets: [String] = [
            "sk-ant-api03-AbCdEfGh1234567890", "sk-proj-AbCdEfGhIjKlMnOpQrStUvWx", "ghp_AbCdEfGhIjKlMnOpQrStUvWxYz012345",
            "github_pat_11ABCDEFG0123456789_abcdefghij", "xoxb-1234567890-abcdefghij", "AKIAIOSFODNN7EXAMPLE",
            "AIza" + "SyA1234567890abcdefghijklmnopqrstuv", ("eyJhbGciOiJIUzI1NiJ9" + ".eyJzdWIiOiIxMjM0NTY3ODkwIn0" + ".dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"),
            "sk_" + "live_51H8abcdefghijklmnop", "glpat" + "-abcdefghij0123456789", "npm_abcdefghijklmnopqrstuvwxyz0123456789",
            Fixture.secretCanary,
        ]
        for secret in secrets {
            let out = Redactor.redact("before \(secret) after")
            #expect(!out.contains(secret), "\(secret)")
            #expect(out.contains("[redacted]") && out.hasPrefix("before ") && out.hasSuffix(" after"), "\(out)")
        }
        #expect(Redactor.redact("Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345") == "Authorization: Bearer [redacted]")
        #expect(Redactor.redact("export API_KEY=" + "abc123def456") == "export API_KEY=[redacted]")
        #expect(Redactor.redact("\"password\": \"correct-horse\"") == "\"password\": \"[redacted]\"")
        #expect(Redactor.redact("postgres://admin:s3cretpw@db.local/x") == "scheme://[redacted]@db.local/x")
        #expect(!Redactor.redact("-----BEGIN RSA PRIVATE KEY-----\nMIIEow\n-----END RSA PRIVATE KEY-----").contains("MIIEow"))
        // Ordinary prose is unchanged.
        let prose = "Updated the token counter and the password reset page; tests pass."
        #expect(Redactor.redact(prose) == prose)
    }

    /// M8-E01: a secret assignment loses its whole value, quoted (any length, spaces included) or
    /// unquoted (to the end of the line or the next separator), and never the lines after it.
    @Test func redactorRemovesWholeAssignedSecretValues() {
        let cases: [(String, String)] = [
            (#"password="correct horse battery staple""#, #"password="[redacted]""#),
            (#"pwd: 'ab cd ef'"#, #"pwd: '[redacted]'"#),
            (#"secret='a b'"#, #"secret='[redacted]'"#),
            (#"token="x y z""#, #"token="[redacted]""#),
            ("api_key=`k e y`", "api_key=`[redacted]`"),
            (#"DB_PASSWORD="hunter2 and more""#, #"DB_PASSWORD="[redacted]""#),
            (#"password="a \"quoted\" b" done"#, #"password="[redacted]" done"#),
            (#"{"client_secret": "s p a c e", "user": "bob"}"#, #"{"client_secret": "[redacted]", "user": "bob"}"#),
            ("passphrase = open sesame now", "passphrase = [redacted]"),
            ("api_key=abc123, region=us-east-1", "api_key=[redacted], region=us-east-1"),
            ("access_key: ab; private_key: cd", "access_key: [redacted]; private_key: [redacted]"),
            ("Authorization: Basic dXNlcjpwYXNz", "Authorization: Basic [redacted]"),
            (#"authorization="Bearer abc def""#, #"authorization="[redacted]""#),
            // Multiline-safe: an unterminated quote or an unquoted value ends at the line end.
            ("password: 'abc def\nNext line stays.", "password: '[redacted]'\nNext line stays."),
            ("token=abc def\nTests pass.", "token=[redacted]\nTests pass."),
            ("secret = \"one two\"\nsecret_count is 3", "secret = \"[redacted]\"\nsecret_count is 3"),
        ]
        for (input, expected) in cases {
            #expect(Redactor.redact(input) == expected, "\(input)")
        }
        for leaked in ["horse", "battery", "staple", "ab cd", "quoted", "s p a c e", "sesame", "dXNlcjpwYXNz", "abc def"] {
            #expect(!cases.map { Redactor.redact($0.0) }.joined(separator: "\n").contains(leaked), "\(leaked)")
        }
        // Ordinary prose that mentions passwords and tokens is unchanged.
        for prose in ["Updated the password reset page and the token counter; tests pass.",
                      "The password field now shows a strength meter, and users who forget their password get an email.",
                      "Secret scanning found nothing. Token usage was 1,200 input tokens."] {
            #expect(Redactor.redact(prose) == prose, "\(prose)")
        }
    }

    @Test func titleAndProjectAreRedactedToo() {
        var c = Self.candidate(activity: Self.t0)
        c.title = "rotate sk-ant-api03-ZZZZZZZZZZZZ now"
        let request = SummaryRequest(candidate: c, tail: "User: hi", provider: .claude, model: "m")
        #expect(!request.prompt.contains("ZZZZZZZZZZZZ"))
    }

    // MARK: Output lines

    @Test func summaryLineIsCutAt90Characters() {
        let long = "Refactoring the recipe card grid so cook times sit under titles and long names wrap cleanly across three columns"
        let (line1, line2) = SummaryText.lines(from: long + "\nNext: " + String(repeating: "detail ", count: 40))!
        #expect(line1.count <= 90)
        #expect(line1.hasSuffix("…"))
        #expect(long.hasPrefix(String(line1.dropLast())))
        #expect(line2!.count <= 140)
        let exact = String(repeating: "a", count: 90)
        #expect(SummaryText.lines(from: exact)!.0 == exact)
        #expect(SummaryText.lines(from: String(repeating: "b", count: 91))!.0.count == 90)
        #expect(SummaryText.lines(from: "  **Fixing tests**  \n\n- Rerunning suite")! == ("Fixing tests", "Rerunning suite"))
        #expect(SummaryText.lines(from: "\"Quoted line\"")!.0 == "Quoted line")
        #expect(SummaryText.lines(from: " \n \n") == nil)
    }

    @Test func echoedFormatLabelsAreRemoved() {
        #expect(SummaryText.lines(from: "Line 1 (≤90 chars): Support agent idle; eval done\nLine 2: Waiting on review")!
                == ("Support agent idle; eval done", "Waiting on review"))
        #expect(SummaryText.lines(from: "summary: Fixing tests")!.0 == "Fixing tests")
        #expect(SummaryText.lines(from: "Status (now): Rerunning suite")!.0 == "Rerunning suite")
        // A real sentence that merely starts with one of the words keeps it.
        #expect(SummaryText.lines(from: "Status page redesign shipped")!.0 == "Status page redesign shipped")
    }

    @Test func cliAnswersParse() {
        #expect(SummaryCLI.answer(provider: .claude, stdout: FakeLauncher.claudeAnswer) == "Fixing dark mode contrast on recipe cards\nSwitching subtitle colour")
        #expect(SummaryCLI.answer(provider: .claude, stdout: Data(#"{"type":"result","subtype":"error_max_turns","is_error":true,"result":"x"}"#.utf8)) == nil)
        #expect(SummaryCLI.answer(provider: .chatgpt, stdout: FakeLauncher.codexAnswer) == "Fixing dark mode contrast on recipe cards")
        #expect(SummaryCLI.answer(provider: .chatgpt, stdout: Data("{\"type\":\"turn.failed\"}\n".utf8)) == nil)
    }

    @Test func cliArgvMakesNoVisibleSessionAndLoadsNoTools() {
        let claude = SummaryCLI.command(provider: .claude, model: "claude-haiku-5-5", executable: "/u/.local/bin/claude", scratch: "/s", home: "/u")!
        let a = claude.arguments
        #expect(a.first == "-p")
        for flag in ["--no-session-persistence", "--safe-mode", "--strict-mcp-config", "--disable-slash-commands"] { #expect(a.contains(flag)) }
        #expect(a[a.firstIndex(of: "--tools")! + 1] == "")
        #expect(a[a.firstIndex(of: "--setting-sources")! + 1] == "")
        #expect(!a.contains("--bare"))
        #expect(claude.directory == "/s")
        let codex = SummaryCLI.command(provider: .chatgpt, model: "gpt-6-luna", executable: "/opt/homebrew/bin/codex", scratch: "/s", home: "/u")!
        let b = codex.arguments
        for flag in ["--ephemeral", "--ignore-user-config", "--ignore-rules", "--skip-git-repo-check"] { #expect(b.contains(flag)) }
        #expect(b[b.firstIndex(of: "-C")! + 1] == "/s")
        #expect(b[b.firstIndex(of: "-s")! + 1] == "read-only")
        let disabled = Set(b.indices.filter { b[$0] == "--disable" }.map { b[$0 + 1] })
        #expect(disabled.isSuperset(of: ["shell_tool", "code_mode_host", "hooks", "multi_agent", "apps", "plugins", "memories"]))
        #expect(b.last == "-")
        // Minimal environment: no inherited tokens or keys.
        for command in [claude, codex] {
            #expect(Set(command.environment.keys).isSubset(of: ["HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "LANG", "NO_COLOR",
                                                                "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "DISABLE_AUTOUPDATER"]))
        }
        // Instructions are the only text in argv; no conversation text can be there (it goes to stdin).
        #expect(SummaryCLI.tomlString("a \"b\" \\ c\n") == "\"a \\\"b\\\" \\\\ c\\n\"")
    }

    // MARK: C6 canary through the whole pipeline

    @Test func canaryReachesOnlyTheRequest() async throws {
        let h = Harness()
        let s = Scratch()
        let path = s.write("claude/p/t.jsonl", Self.claudeTranscript(canary: Fixture.bodyCanary) + Self.secretLine())
        let launcher = FakeLauncher()
        let service = h.service(transcripts: FileTranscriptSource(), launcher: launcher)
        let report = await service.step([Self.candidate(state: .idle, activity: Self.t0.addingTimeInterval(-100), paths: [path])], now: Self.t0)
        #expect(report?.outcome == .made)
        // The body canary is in the request (stdin), the secret canary was redacted before sending.
        let input = String(decoding: launcher.inputs[0], as: UTF8.self)
        #expect(input.contains(Fixture.bodyCanary))
        #expect(!input.contains(Fixture.secretCanary))
        // Never in argv or environment.
        let argv = launcher.commands[0].arguments.joined(separator: " ") + launcher.commands[0].environment.values.joined(separator: " ")
        #expect(!argv.contains(Fixture.bodyCanary) && !argv.contains(Fixture.secretCanary))
        // Nowhere in the store, its WAL, the app folder or the scratch folder.
        let files = (FileManager.default.enumerator(atPath: h.dir.path)?.allObjects as? [String] ?? []).map { h.dir.appendingPathComponent($0).path }
        #expect(files.contains { $0.hasSuffix("-wal") })
        for file in files {
            #expect(!bytesContain(file, Fixture.bodyCanary), "\(file)")
            #expect(!bytesContain(file, Fixture.secretCanary), "\(file)")
        }
        h.store.checkpointWAL()
        for file in files { #expect(!bytesContain(file, Fixture.bodyCanary), "\(file)") }
        // The report (what the app logs) carries counts only.
        #expect(!"\(report!)".contains(Fixture.bodyCanary))
        // Stored: summary text, hash and metadata only.
        let stored = h.store.loadSummaries()["claude:a"]!
        #expect(stored.line1 == "Fixing dark mode contrast on recipe cards")
        #expect(stored.inputHash.count == 64)
    }

    /// M8-E01 through the real paths: transcript file → tail → request (stdin), and CLI answer → store.
    @Test func quotedPassphraseIsRemovedFromRequestAndStoredSummary() async throws {
        let h = Harness()
        let s = Scratch()
        let assignment = #"password="correct horse battery staple""#
        let line = String(decoding: try JSONSerialization.data(withJSONObject: ["type": "user", "message": ["role": "user",
            "content": "Use \(assignment) on staging"]]), as: UTF8.self) + "\n"
        let path = s.write("claude/p/t.jsonl", Self.claudeTranscript(canary: "c") + line)
        let launcher = FakeLauncher()
        launcher.stdout = try JSONSerialization.data(withJSONObject: ["type": "result", "subtype": "success", "is_error": false,
            "result": "Setting \(assignment) on staging"])
        let service = h.service(transcripts: FileTranscriptSource(), launcher: launcher)
        let report = await service.step([Self.candidate(state: .idle, activity: Self.t0.addingTimeInterval(-100), paths: [path])], now: Self.t0)
        #expect(report?.outcome == .made)
        let input = String(decoding: launcher.inputs[0], as: UTF8.self)
        #expect(input.contains("on staging") && input.contains("[redacted]"))
        for word in ["correct", "horse", "battery", "staple"] { #expect(!input.contains(word), "request has \(word)") }
        let stored = h.store.loadSummaries()["claude:a"]!
        #expect(stored.line1 == #"Setting password="[redacted]" on staging"#)
    }

    /// M8-E03: redaction that runs past its budget sends nothing: no process starts, nothing is
    /// stored, the hourly cap is not used, and Settings can say why.
    @Test func redactionPastItsBudgetSendsNothing() async {
        let h = Harness()
        let launcher = FakeLauncher()
        let service = h.service(launcher: launcher, redactionBudget: 0)
        let report = await service.step([Self.candidate(state: .idle, activity: Self.t0.addingTimeInterval(-100))], now: Self.t0)
        #expect(report?.outcome == .redactionOverBudget)
        #expect(report?.called == false && report?.requestBytes == 0)
        #expect(launcher.commands.isEmpty && launcher.inputs.isEmpty)
        #expect(await service.launches == 0)
        #expect(h.store.loadSummaries().isEmpty)
        #expect(h.store.loadSummaryCalls(since: .distantPast).isEmpty)
    }

    /// The deadline is checked inside the work, not only before it: a 1 MB text stops early.
    @Test func redactionStopsAtItsDeadline() {
        #expect(Redactor.redact("password=x", deadline: .distantPast) == nil)
        #expect(TranscriptTail.finish("User: password=x", deadline: .distantPast) == nil)
        let big = String(repeating: "a- password=x ", count: 80_000)
        // Starts inside the budget (the entry check passes), so nil means it stopped part-way.
        #expect(Redactor.redact(big, deadline: Date().addingTimeInterval(0.001)) == nil)
        // Within budget the same call redacts; the convenience form never returns unredacted text.
        #expect(Redactor.redact("password=x", deadline: Date().addingTimeInterval(1)) == "password=[redacted]")
        #expect(Redactor.redact("password=x") == "password=[redacted]")
    }

    static func secretLine() -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: ["type": "user", "message": ["role": "user",
            "content": "my key is \(Fixture.secretCanary)"]]), as: UTF8.self) + "\n"
    }

    @Test func sameRequestMakesNoSecondCall() async {
        let h = Harness()
        let s = Scratch()
        let path = s.write("t.jsonl", Self.claudeTranscript(canary: "c"))
        let launcher = FakeLauncher()
        let service = h.service(transcripts: FileTranscriptSource(), launcher: launcher)
        _ = await service.step([Self.candidate(state: .idle, activity: Self.t0.addingTimeInterval(-100), paths: [path])], now: Self.t0)
        // Activity moved (e.g. a token record) but the text is the same: no call.
        let report = await service.step([Self.candidate(state: .idle, activity: Self.t0.addingTimeInterval(10), paths: [path])], now: Self.t0.addingTimeInterval(200))
        #expect(report?.outcome == .unchanged)
        #expect(launcher.count == 1)
    }

    @Test func nonEmptyScratchFailsClosed() async {
        let h = Harness()
        _ = Scratch()
        try? FileManager.default.createDirectory(atPath: h.scratch, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: h.scratch + "/AGENTS.md", contents: Data("x".utf8))
        let launcher = FakeLauncher()
        let report = await h.service(launcher: launcher).step([Self.candidate(state: .idle, activity: Self.t0.addingTimeInterval(-100))], now: Self.t0)
        #expect(report?.outcome == .scratchUnavailable)
        #expect(launcher.count == 0)
    }

    @Test func missingCLIIsReportedWithoutLaunching() async {
        let h = Harness()
        let launcher = FakeLauncher()
        let service = SummaryService(settings: SummarySettings(provider: .claude), store: h.store, transcripts: StaticTranscript(),
                                     launcher: launcher, locator: CLILocator(home: "/nonexistent", candidates: { _, _ in ["/nonexistent/claude"] }),
                                     scratch: h.scratch, now: Self.t0)
        let report = await service.step([Self.candidate(state: .idle, activity: Self.t0.addingTimeInterval(-100))], now: Self.t0)
        #expect(report?.outcome == .cliMissing)
        #expect(launcher.count == 0)
    }

    // MARK: C7: summaries on, nothing changes → no call

    @Test func quietShelfMakesNoCallsWithSummariesOn() async throws {
        let s = Scratch()
        s.installFixtures()
        let h = Harness()
        let engine = Engine(collectors: [ClaudeCodeCollector(root: s.claudeRoot), CodexCollector(codexHome: s.codexHome)], store: nil, home: s.path)
        let transcripts = CountingTranscript()
        let launcher = FakeLauncher()
        let service = h.service(transcripts: transcripts, launcher: launcher)
        var snapshot = await engine.indexToCompletion()
        // Simulated clock starting 2 min after the newest fixture activity, so threads are eligible.
        let newest = try #require(SummaryCandidate.from(snapshot.projects).map(\.lastActivityAt).max())
        var now = newest.addingTimeInterval(120)
        while await service.step(SummaryCandidate.from(snapshot.projects), now: now) != nil {}
        let firstRound = launcher.count
        let reads = transcripts.count
        #expect(firstRound > 0)
        // Then 2 h of passes every minute with no source change: no read, no call.
        for _ in 0..<120 {
            now = now.addingTimeInterval(60)
            snapshot = await engine.pass()
            #expect(await service.step(SummaryCandidate.from(snapshot.projects), now: now) == nil)
        }
        #expect(launcher.count == firstRound)
        #expect(transcripts.count == reads)
    }

    /// Process launching is confined to `SummaryRunner.swift` (the summary CLIs), like networking is
    /// confined to `UsageLive.swift`.
    @Test func processLaunchIsConfinedToTheSummaryRunner() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for folder in ["Sources/LighthouseCore", "App/Lighthouse"] {
            let dir = root.appendingPathComponent(folder)
            for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name.hasSuffix(".swift") {
                let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
                for word in ["Process(", "posix_spawn", "NSTask", "popen("] where name != "SummaryRunner.swift" {
                    #expect(!text.contains(word), "\(folder)/\(name) uses \(word)")
                }
            }
        }
    }
}

// MARK: Test doubles

/// A temp store and a scratch folder; the fake CLI paths exist so the locator finds them.
final class Harness: @unchecked Sendable {
    let base = Scratch()
    let dir: URL
    let store: Store
    let scratch: String
    let locator: CLILocator

    init() {
        dir = base.url.appendingPathComponent("AppSupport/Lighthouse")
        store = try! Store(url: dir.appendingPathComponent("lighthouse.sqlite"))
        scratch = base.url.appendingPathComponent("summary-scratch").path
        let bin = base.dir("bin")
        for name in ["claude", "codex"] {
            FileManager.default.createFile(atPath: bin + "/" + name, contents: Data("#!/bin/sh\nexit 9\n".utf8), attributes: [.posixPermissions: 0o755])
        }
        locator = CLILocator(home: base.path, candidates: { provider, _ in [bin + "/" + (provider == .claude ? "claude" : "codex")] })
    }

    func service(settings: SummarySettings = SummarySettings(provider: .claude), transcripts: TranscriptSource = StaticTranscript(),
                 launcher: FakeLauncher, redactionBudget: TimeInterval = Redactor.budget, now: Date = SummaryTests.t0) -> SummaryService {
        SummaryService(settings: settings, store: store, transcripts: transcripts, launcher: launcher, locator: locator, scratch: scratch,
                       home: base.path, redactionBudget: redactionBudget, now: now)
    }
}

struct StaticTranscript: TranscriptSource {
    func tail(paths: [String]) -> String? { "User: fix it\n\nAssistant: fixing \(paths.first ?? "")" }
}

final class CountingTranscript: TranscriptSource, @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    var count: Int { lock.withLock { reads } }
    func tail(paths: [String]) -> String? {
        lock.withLock { reads += 1 }
        return "User: work on \(paths.first ?? "")"
    }
}

final class FakeLauncher: SummaryProcessLauncher, @unchecked Sendable {
    static let claudeAnswer = Data(#"{"type":"result","subtype":"success","is_error":false,"result":"Fixing dark mode contrast on recipe cards\nSwitching subtitle colour"}"#.utf8)
    static let codexAnswer = Data(("{\"type\":\"thread.started\"}\n{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Fixing dark mode contrast on recipe cards\"}}\n"
                                   + "{\"type\":\"turn.completed\"}\n").utf8)
    private let lock = NSLock()
    private var _commands: [SummaryCommand] = []
    private var _inputs: [Data] = []
    private var _timeouts: [TimeInterval] = []
    private var running = 0
    private var _maxConcurrent = 0
    var stdout = FakeLauncher.claudeAnswer
    let delay: Double
    let timedOut: Bool
    let gated: Bool
    private var gateOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(delay: Double = 0, timedOut: Bool = false, gated: Bool = false) {
        self.delay = delay
        self.timedOut = timedOut
        self.gated = gated
    }

    /// Releases every call held by the gate, and every later one.
    func open() {
        let held = lock.withLock { gateOpen = true; defer { waiters.removeAll() }; return waiters }
        held.forEach { $0.resume() }
    }

    var commands: [SummaryCommand] { lock.withLock { _commands } }
    var inputs: [Data] { lock.withLock { _inputs } }
    var timeouts: [TimeInterval] { lock.withLock { _timeouts } }
    var count: Int { commands.count }
    var maxConcurrent: Int { lock.withLock { _maxConcurrent } }

    func run(_ command: SummaryCommand, input: Data, timeout: TimeInterval) async -> ProcessOutcome {
        let out: Data = lock.withLock {
            _commands.append(command); _inputs.append(input); _timeouts.append(timeout)
            running += 1; _maxConcurrent = max(_maxConcurrent, running)
            return stdout
        }
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
        if gated {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock { gateOpen ? true : { waiters.append(c); return false }() }
                if resumeNow { c.resume() }
            }
        }
        lock.withLock { running -= 1 }
        if timedOut { return ProcessOutcome(launched: true, exitCode: 15, timedOut: true, stdout: Data(), stderrBytes: 0, seconds: timeout) }
        return ProcessOutcome(launched: true, exitCode: 0, timedOut: false, stdout: out, stderrBytes: 0, seconds: 0.01)
    }
}
