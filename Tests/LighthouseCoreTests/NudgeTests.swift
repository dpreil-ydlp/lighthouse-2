import Foundation
import Testing
@testable import LighthouseCore

/// SPEC 2.11 (owner 2026-11-03): "a limit of 3 before declaring a thread in need of my help and only
/// parent threads". Nudges go only to stalled T3 parent threads, 15 min apart, at most 3 per run.
@Suite struct NudgePolicyTests {
    let now = Date(timeIntervalSince1970: 1800000000.1234567)

    func stalled(_ id: String = "th1", app: OwningApp = .t3, minutesQuiet: Double = 40, runStartedMinutesAgo: Double = 90) -> SessionThread {
        var t = SessionThread(id: "t3:\(id)", owningApp: app, providerIdentities: [ProviderIdentity(provider: .codex, nativeId: id)],
                              title: "Thread \(id)", cwd: "/x", state: .running, sourceReadAt: now,
                              lastActivityAt: now.addingTimeInterval(-minutesQuiet * 60), lastProgressAt: now.addingTimeInterval(-minutesQuiet * 60))
        t.runningSince = now.addingTimeInterval(-runStartedMinutesAgo * 60)
        t.t3ThreadId = id
        return t
    }

    /// The shelf at `time`, with each thread's source read just then (as a live poll would).
    func project(_ threads: [SessionThread], at time: Date? = nil) -> ProjectSummary {
        let identity = ProjectIdentity(root: "/P/a", name: "a", kind: .git)
        let read = threads.map { t -> SessionThread in var t = t; t.sourceReadAt = time ?? now; return t }
        return ShelfBuilder.summarize(threads: read, identities: Array(repeating: identity, count: threads.count), now: time ?? now)[0]
    }

    @Test func idleParentWithAuthorizedWorkUsesTheRealConsumer() {
        var t = stalled()
        t.state = .idle
        t.continueWorkAt = t.lastActivityAt
        #expect(NudgePolicy.next([project([t])], records: [:], now: now)?.number == 1)
    }

    @Test func idleExclusionsAndEpisodeSurviveRestAndReload() throws {
        var t = stalled()
        t.state = .idle
        t.continueWorkAt = t.lastActivityAt
        for variant in 0..<6 {
            var excluded = t
            switch variant {
            case 0: excluded.continueWorkAt = nil // finished objective or no authority
            case 1: excluded.state = .stopped
            case 2: excluded.asksOwnerAt = now
            case 3: excluded.settledAt = now
            case 4: excluded.continueWorkAt = now.addingTimeInterval(-10000) // stale judgment
            default: excluded.state = .waitingForOwner
            }
            #expect(NudgePolicy.next([project([excluded])], records: [:], now: now) == nil)
        }
        t.sourceReadAt = now.addingTimeInterval(-3600)
        #expect(!NudgePolicy.idleWork(t, now: now))
        t.sourceReadAt = now
        let scratch = Scratch()
        let store = try Store(url: scratch.url.appendingPathComponent("n.sqlite"))
        let r = NudgeRecord(threadId: t.id, episodeStart: now.addingTimeInterval(-3600), count: 3,
                            lastSentAt: now.addingTimeInterval(-1800), restingSince: now.addingTimeInterval(-1200))
        try store.saveNudge(r)
        let kept = NudgePolicy.reconcile(try store.loadNudges(), threads: [t], now: now).records
        #expect(kept[t.id]?.count == 3)
        #expect(NudgePolicy.next([project([t])], records: kept, now: now) == nil)
        t.nudge = NudgeMark(count: 3, lastSentAt: r.lastSentAt, episodeKey: r.episodeKey)
        #expect(AttentionRules.items(for: t, now: now).contains { $0.kind == .waitingForOwner })
    }

    @Test func summaryEvidenceFlowsThroughScannerAndStore() throws {
        let scratch = Scratch()
        let helper = ReplyDetectorTests()
        let path = scratch.write("idle.jsonl", [helper.line("user", "Implement the feature and run its checks."),
            helper.line("assistant", "The first step passed. I will now run the remaining checks.")].joined(separator: "\n") + "\n")
        var t = stalled()
        t.state = .idle
        t.transcriptPaths = [path]
        let store = try Store(url: scratch.url.appendingPathComponent("s.sqlite"))
        store.saveSummary(ThreadSummary(threadId: t.id, line1: "Checks remain", line2: nil, madeAt: now,
            activityAt: t.lastActivityAt, inputHash: "fixture", provider: .claude, model: "fixture",
            needsOwner: false, continueWork: true))
        var scanner = ReplyScanner()
        let marked = scanner.mark([t], now: now, judgments: ReplyJudgment.from(store.loadSummaries()))
        #expect(NudgePolicy.next([project(marked)], records: [:], now: now)?.t3ThreadId == "th1")
        let noModel = scanner.mark([t], now: now)
        #expect(NudgePolicy.next([project(noModel)], records: [:], now: now) == nil)
        #expect(SummaryText.continueWork(from: "Checks remain\nCONTINUE_WORK: yes") == true)
        #expect(SummaryText.lines(from: "Checks remain\nCONTINUE_WORK: yes\nNEEDS_OWNER: no")?.1 == nil)
    }

    @Test func delayedJudgmentPreservesEpisodeAcrossReload() throws {
        let scratch = Scratch()
        let helper = ReplyDetectorTests()
        let path = scratch.write("delayed.jsonl", [helper.line("user", "Finish the authorized checks."),
            helper.line("assistant", "The first check passed. More checks remain.")].joined(separator: "\n") + "\n")
        var t = stalled()
        t.state = .idle
        t.transcriptPaths = [path]
        let store = try Store(url: scratch.url.appendingPathComponent("delay.sqlite"))
        let original = NudgeRecord(threadId: t.id, episodeStart: now.addingTimeInterval(-3600), count: 2,
                                   lastSentAt: now.addingTimeInterval(-1800))
        var scanner = ReplyScanner()
        let unknown = scanner.mark([t], now: now, judgments: [:])[0]
        let first = NudgePolicy.reconcile([t.id: original], threads: [unknown], now: now)
        for record in first.records.values { try store.saveNudge(record) }
        let later = now.addingTimeInterval(11 * 60)
        let retained = NudgePolicy.reconcile(try store.loadNudges(), threads: [unknown], now: later)
        #expect(retained.records[t.id]?.count == 2)
        #expect(NudgePolicy.next([project([unknown], at: later)], records: retained.records, now: later) == nil)
        let stale = scanner.mark([t], now: later, judgments: [t.id: ReplyJudgment(activityAt: t.lastActivityAt.addingTimeInterval(-1), needsOwner: false, continueWork: true)])[0]
        #expect(stale.continueWorkJudgedAt == nil && stale.continueWorkAt == nil)
        let negative = scanner.mark([t], now: later, judgments: [t.id: ReplyJudgment(activityAt: t.lastActivityAt, needsOwner: false, continueWork: false)])[0]
        #expect(negative.continueWorkJudgedAt == t.lastActivityAt && negative.continueWorkAt == nil)
        let positive = scanner.mark([t], now: later, judgments: [t.id: ReplyJudgment(activityAt: t.lastActivityAt, needsOwner: false, continueWork: true)])[0]
        let resumed = NudgePolicy.next([project([positive], at: later)], records: retained.records, now: later)
        #expect(resumed?.number == 3)
        #expect(resumed?.episodeStart == original.episodeStart)
        if let resumed {
            let exhausted = NudgePolicy.attempted(resumed, at: later)
            try store.saveNudge(exhausted)
            let again = NudgePolicy.reconcile(try store.loadNudges(), threads: [unknown], now: later.addingTimeInterval(11 * 60))
            #expect(again.records[t.id]?.count == 3)
            #expect(NudgePolicy.next([project([positive], at: later)], records: again.records, now: later) == nil)
        }
    }

    @Test(arguments: ["", "CONTINUE_WORK: maybe", "CONTINUE_WORK: no"])
    func serviceJudgmentPreservesEpisode(marker: String) async throws {
        let h = Harness()
        let helper = ReplyDetectorTests()
        let path = h.base.write("producer.jsonl", [helper.line("user", "Finish the authorized checks."),
            helper.line("assistant", "The first check passed. More checks remain.")].joined(separator: "\n") + "\n")
        var t = stalled()
        t.state = .idle
        t.transcriptPaths = [path]
        let launcher = FakeLauncher()
        launcher.stdout = try JSONSerialization.data(withJSONObject: ["type": "result", "subtype": "success", "is_error": false,
            "result": "Checks remain\nNEEDS_OWNER: no\n" + marker])
        let transcripts = CountingTranscript()
        let service = h.service(transcripts: transcripts, launcher: launcher, now: now)
        let candidate = SummaryTests.candidate(t.id, activity: t.lastActivityAt, paths: [path])
        #expect(await service.step([candidate], now: now)?.outcome == .made)
        let negative = marker == "CONTINUE_WORK: no"
        let reloaded = try Store(url: h.dir.appendingPathComponent("lighthouse.sqlite"))
        #expect(reloaded.loadSummaries()[t.id]?.continueWork == (negative ? false : nil))
        var scanner = ReplyScanner()
        let marked = scanner.mark([t], now: now, judgments: ReplyJudgment.from(reloaded.loadSummaries()))
        let original = NudgeRecord(threadId: t.id, episodeStart: now.addingTimeInterval(-3600), count: 2,
                                   lastSentAt: now.addingTimeInterval(-1800))
        let first = NudgePolicy.reconcile([t.id: original], threads: marked, now: now)
        for record in first.records.values { try h.store.saveNudge(record) }
        let later = now.addingTimeInterval(660)
        let retained = NudgePolicy.reconcile(try reloaded.loadNudges(), threads: marked, now: later)
        #expect(NudgePolicy.next([project(marked, at: later)], records: retained.records, now: later) == nil)
        #expect(negative ? retained.records.isEmpty : retained.records[t.id]?.count == 2)
        // Missing markers must not select/read on every poll or call the CLI again for the same input.
        for second in 1..<600 {
            #expect(await service.step([candidate], now: now.addingTimeInterval(Double(second))) == nil)
        }
        #expect(transcripts.count == 1)
        _ = await service.step([candidate], now: later)
        let reads = transcripts.count
        for second in 661..<1260 {
            #expect(await service.step([candidate], now: now.addingTimeInterval(Double(second))) == nil)
        }
        #expect(transcripts.count == reads)
        #expect(launcher.count == 1)
        let restarted = h.service(transcripts: transcripts, launcher: launcher, now: later)
        _ = await restarted.step([candidate], now: later)
        #expect(await restarted.step([candidate], now: later.addingTimeInterval(1)) == nil)
        #expect(launcher.count == 1)
        // A changed request produces positive evidence through the same service, never injected judgments.
        t.lastActivityAt = later.addingTimeInterval(-60)
        launcher.stdout = try JSONSerialization.data(withJSONObject: ["type": "result", "subtype": "success", "is_error": false,
            "result": "Continue authorized checks\nNEEDS_OWNER: no\nCONTINUE_WORK: yes"])
        let changed = SummaryTests.candidate(t.id, activity: t.lastActivityAt, paths: [path + ".changed"])
        #expect(await restarted.step([changed], now: later)?.outcome == .made)
        let positive = scanner.mark([t], now: later, judgments: ReplyJudgment.from(reloaded.loadSummaries()))
        let eligibleAt = later.addingTimeInterval(1800)
        let resumed = NudgePolicy.next([project(positive, at: eligibleAt)], records: retained.records, now: eligibleAt)
        #expect(resumed?.number == (negative ? 1 : 3))
        if !negative { #expect(resumed?.episodeStart == original.episodeStart) }
    }

    @Test func negativeJudgmentAndStopsStillEndTheEpisode() {
        var t = stalled()
        t.state = .idle
        let record = NudgeRecord(threadId: t.id, episodeStart: now.addingTimeInterval(-3600), count: 3,
                                 lastSentAt: now.addingTimeInterval(-1800))
        t.continueWorkJudgedAt = t.lastActivityAt
        let first = NudgePolicy.reconcile([t.id: record], threads: [t], now: now)
        #expect(first.records[t.id]?.restingSince == now)
        #expect(NudgePolicy.reconcile(first.records, threads: [t], now: now.addingTimeInterval(600)).removed == [t.id])
        t.continueWorkJudgedAt = nil
        t.state = .stopped
        let stopped = NudgePolicy.reconcile([t.id: record], threads: [t], now: now)
        #expect(NudgePolicy.reconcile(stopped.records, threads: [t], now: now.addingTimeInterval(600)).removed == [t.id])
        t.state = .idle
        t.settledAt = now
        #expect(NudgePolicy.reconcile([t.id: record], threads: [t], now: now).removed == [t.id])
        t.settledAt = nil
        #expect(NudgePolicy.reconcile([t.id: record], threads: [t], now: now.addingTimeInterval(86400)).removed == [t.id])
    }

    @Test func aStalledT3ParentGetsTheFirstNudge() {
        let t = stalled()
        let next = NudgePolicy.next([project([t])], records: [:], now: now)
        #expect(next?.t3ThreadId == "th1")
        #expect(next?.number == 1)
        #expect(next?.episodeStart == now)
    }

    /// The nearest wrong result: a 4th nudge. After 3 the thread is handed to the owner instead.
    @Test func atMostThreeNudgesFifteenMinutesApartThenNeedsYou() {
        let t = stalled()
        var records: [String: NudgeRecord] = [:]
        var clock = now
        var sent: [Int] = []
        for _ in 0..<12 {
            if let next = NudgePolicy.next([project([t], at: clock)], records: records, now: clock) {
                records[t.id] = NudgePolicy.attempted(next, at: clock)
                sent.append(next.number)
            }
            clock = clock.addingTimeInterval(5 * 60)
        }
        #expect(sent == [1, 2, 3])
        #expect(records[t.id]?.count == 3 && records[t.id]?.episodeStart == now)
        // Sent at 0, 15 and 30 min: the third is at least 15 min after the second.
        let record = records[t.id]!
        #expect(record.lastSentAt == now.addingTimeInterval(30 * 60))

        var marked = t
        marked.nudge = NudgeMark(count: record.count, lastSentAt: record.lastSentAt, episodeKey: record.episodeKey)
        let early = record.lastSentAt!.addingTimeInterval(14 * 60), late = record.lastSentAt!.addingTimeInterval(15 * 60)
        marked.sourceReadAt = early
        let before = AttentionRules.items(for: marked, now: early)
        #expect(!before.contains { $0.kind == .waitingForOwner })
        #expect(before.first { $0.kind == .stalledThread }?.label == "No progress · nudged 3 of 3 · Thread th1")
        marked.sourceReadAt = late
        let after = AttentionRules.items(for: marked, now: late)
        let handed = after.filter { $0.kind == .waitingForOwner }
        #expect(handed.count == 1)
        #expect(handed.first?.label == "Still stuck after 3 nudges · Thread th1")
        #expect(handed.first?.id == "waitingForOwner|t3:th1|nudged-\(record.episodeKey)")
        #expect(handed.first?.kind.bucket == .needsYou)
    }

    /// The nearest wrong result for the count: a nudge makes T3 start a new run, and a count keyed on
    /// the run would start again at 1 forever. A new run must not reset it.
    @Test func aNewRunDoesNotResetTheCount() {
        var t = stalled(runStartedMinutesAgo: 50)
        let record = NudgeRecord(threadId: t.id, episodeStart: now.addingTimeInterval(-3 * 3600), count: 3, lastSentAt: now.addingTimeInterval(-3600))
        t.runningSince = now.addingTimeInterval(-45 * 60)
        #expect(NudgePolicy.next([project([t])], records: [t.id: record], now: now) == nil)
        #expect(NudgePolicy.reconcile([t.id: record], threads: [t], now: now).records[t.id]?.count == 3)
    }

    /// The episode ends after 10 min not running (the turn finished, or the owner took over), or 24 h.
    @Test func restOrADayEndsTheEpisode() {
        let t = stalled()
        let record = NudgeRecord(threadId: t.id, episodeStart: now.addingTimeInterval(-3600), count: 3, lastSentAt: now.addingTimeInterval(-1800))
        var idle = t
        idle.state = .idle
        idle.continueWorkJudgedAt = idle.lastActivityAt // current negative judgment permits rest
        // Seen not running: noted, kept.
        let first = NudgePolicy.reconcile([t.id: record], threads: [idle], now: now)
        #expect(first.records[t.id]?.restingSince == now && first.changed.count == 1)
        // Running again within 10 min: the note is cleared, the count stays.
        let back = NudgePolicy.reconcile(first.records, threads: [t], now: now.addingTimeInterval(5 * 60))
        #expect(back.records[t.id]?.restingSince == nil && back.records[t.id]?.count == 3)
        // Not running for 10 min: the episode ends.
        let rested = NudgePolicy.reconcile(first.records, threads: [idle], now: now.addingTimeInterval(10 * 60))
        #expect(rested.records.isEmpty && rested.removed == [t.id])
        // 24 h after the first nudge, or the thread gone: ended.
        #expect(NudgePolicy.reconcile([t.id: record], threads: [t], now: now.addingTimeInterval(23 * 3600)).removed == [t.id])
        #expect(NudgePolicy.reconcile([t.id: record], threads: [], now: now).removed == [t.id])
        // A new episode starts at nudge 1.
        let fresh = NudgePolicy.next([project([t], at: now.addingTimeInterval(23 * 3600))], records: [:], now: now.addingTimeInterval(23 * 3600))
        #expect(fresh?.number == 1)
    }

    @Test func onlyRunningStalledT3ParentThreads() {
        // Claude Code-owned: no stall is ever raised, and it is not a T3 thread.
        #expect(NudgePolicy.next([project([stalled(app: .claudeCode)])], records: [:], now: now) == nil)
        // A Codex app thread can stall but cannot take a message.
        var codex = stalled(app: .codex)
        #expect(NudgePolicy.next([project([codex])], records: [:], now: now) == nil)
        codex.t3ThreadId = nil
        #expect(NudgePolicy.target(codex) == nil)
        // Not stalled yet (20 min quiet).
        #expect(NudgePolicy.next([project([stalled(minutesQuiet: 20)])], records: [:], now: now) == nil)
        // Waiting on the owner, idle or stopped: not running, so never nudged.
        for state in [ThreadState.waitingForOwner, .idle, .stopped, .unknown] {
            var t = stalled()
            t.state = state
            #expect(NudgePolicy.next([project([t])], records: [:], now: now) == nil, "\(state)")
        }
        // A T3 thread id that is not a plain id is never sent to.
        var odd = stalled()
        odd.t3ThreadId = "../x"
        #expect(NudgePolicy.target(odd) == nil)
    }

    /// Subagents are never nudged: a silent subagent raises its own item, and its parent is not stalled.
    @Test func subagentsAreNeverNudged() {
        var parent = stalled()
        var sub = Subagent(id: "t3:child", name: "worker", provider: .codex, state: .running, sourceReadAt: now,
                           lastActivityAt: now.addingTimeInterval(-40 * 60))
        sub.t3ThreadId = "child"
        parent.subagents = [sub]
        let p = project([parent])
        #expect(p.attentionItems.contains { $0.kind == .silentSubagent })
        let next = NudgePolicy.next([p], records: [:], now: now)
        #expect(next == nil || next?.t3ThreadId == "th1")
        #expect(next?.t3ThreadId != "child")
    }

    @Test func aFailedSendDoesNotCountAndWaitsBeforeTheRetry() {
        let t = stalled()
        let first = NudgePolicy.next([project([t])], records: [:], now: now)!
        let failed = NudgePolicy.failed(first, previous: nil, at: now)
        #expect(failed.count == 0)
        #expect(NudgePolicy.next([project([t])], records: [t.id: failed], now: now.addingTimeInterval(10 * 60)) == nil)
        let retry = NudgePolicy.next([project([t], at: now.addingTimeInterval(15 * 60))], records: [t.id: failed], now: now.addingTimeInterval(15 * 60))
        #expect(retry?.number == 1)
    }

    @Test func theMessageIsFixedAndNumbered() {
        #expect(NudgePolicy.message(number: 2).hasPrefix("Lighthouse (nudge 2 of 3): this thread has shown no progress for 30 minutes."))
        #expect(NudgePolicy.requestId(threadId: "th1", episodeKey: "100", number: 2) == "lighthouse-nudge-th1-100-2")
    }

    @Test func recordsAndTheSwitchPersist() throws {
        let scratch = Scratch()
        let store = try Store(url: scratch.url.appendingPathComponent("s.sqlite"))
        let record = NudgeRecord(threadId: "t3:th1", episodeStart: Date(timeIntervalSince1970: 900), count: 2,
                                 lastSentAt: Date(timeIntervalSince1970: 1000), lastFailedAt: nil, restingSince: Date(timeIntervalSince1970: 1100))
        try store.saveNudge(record)
        #expect(try store.loadNudges()["t3:th1"] == record)
        try store.deleteNudge("t3:th1")
        #expect(try store.loadNudges().isEmpty)
        #expect(AppSettings().nudgeOn == false)
        var settings = AppSettings()
        settings.nudgeOn = true
        try store.saveAppSettings(settings)
        #expect(try store.loadAppSettings().nudgeOn)
    }
}

/// T3Link against a fake T3 server and a fake `t3` command: no real T3, no network.
@Suite struct T3LinkTests {
    final class FakeT3: T3Transport, @unchecked Sendable {
        let lock = NSLock()
        var requests: [T3HTTPRequest] = []
        var rtc = "full-access"
        var sendError: String?
        var expiresIn = 30 * 86400

        static func token(claims: [String: Any]) -> String {
            T3Link.base64URL(try! JSONSerialization.data(withJSONObject: claims)) + ".sig"
        }

        func send(_ request: T3HTTPRequest) async throws -> T3HTTPResponse {
            lock.withLock { requests.append(request) }
            let body = request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            func json(_ object: [String: Any], headers: [String: String] = [:]) -> T3HTTPResponse {
                T3HTTPResponse(status: 200, headers: ["content-type": "application/json"].merging(headers) { $1 },
                               body: try! JSONSerialization.data(withJSONObject: object))
            }
            switch request.path {
            case "/.well-known/oauth-authorization-server":
                return json(["registration_endpoint": "http://127.0.0.1:3773/oauth/mcp/register", "token_endpoint": "http://127.0.0.1:3773/oauth/mcp/token"])
            case "/oauth/mcp/register":
                return json(["client_id": "client-1"])
            case "/oauth/mcp/decision":
                let authorization = body?["authorization"] as? [String: Any]
                let state = authorization?["state"] as? String ?? ""
                return json(["redirectTo": "http://127.0.0.1:51829/t3-callback?code=code-1&state=\(state)"])
            case "/oauth/mcp/token":
                return json(["access_token": Self.token(claims: ["sid": "session-1", "scopes": ["orchestration:read", "orchestration:operate"], "rtc": rtc]),
                             "expires_in": expiresIn])
            case "/mcp":
                if body?["method"] as? String == "tools/call", let sendError {
                    return json(["jsonrpc": "2.0", "id": 2, "result": ["isError": true, "content": [["type": "text", "text": sendError]]]])
                }
                return json(["jsonrpc": "2.0", "id": body?["id"] ?? 0, "result": [:] as [String: Any]], headers: ["mcp-session-id": "mcp-1"])
            default:
                return T3HTTPResponse(status: 404, headers: [:], body: Data())
            }
        }
    }

    final class FakeCLI: SummaryProcessLauncher, @unchecked Sendable {
        let lock = NSLock()
        var commands: [[String]] = []
        func run(_ command: SummaryCommand, input: Data, timeout: TimeInterval) async -> ProcessOutcome {
            lock.withLock { commands.append(command.arguments) }
            let out = command.arguments.prefix(3) == ["auth", "pairing", "create"] ? Data(#"{"credential":"PAIR-1"}"#.utf8) : Data()
            return ProcessOutcome(launched: true, exitCode: 0, timedOut: false, stdout: out, stderrBytes: 0, seconds: 0)
        }
    }

    /// The scratch folder lives as long as the test (it is deleted when released).
    let scratch = Scratch()

    func setUp() -> (T3Link, FakeT3, FakeCLI, URL) {
        let home = scratch.url.appendingPathComponent("home")
        let bin = home.appendingPathComponent(".t3/bin")
        try! FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let cli = bin.appendingPathComponent("t3").path
        FileManager.default.createFile(atPath: cli, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        let folder = scratch.url.appendingPathComponent("AppSupport/Lighthouse/t3")
        let t3 = FakeT3(), launcher = FakeCLI()
        return (T3Link(folder: folder, home: home.path, transport: t3, launcher: launcher), t3, launcher, folder)
    }

    @Test func connectSavesAFullAccessTokenInAPrivateFile() async throws {
        let (link, t3, cli, folder) = setUp()
        let token = try await link.connect()
        #expect(token.access == "full-access" && token.sessionId == "session-1")
        let pairing = cli.commands.first!
        #expect(Array(pairing.prefix(3)) == ["auth", "pairing", "create"])
        #expect(pairing.contains("--ttl") && pairing.contains("5m"))
        // The pairing code goes to T3's decision endpoint with Full access.
        let decision = t3.requests.first { $0.path == "/oauth/mcp/decision" }!
        let body = try JSONSerialization.jsonObject(with: decision.body!) as! [String: Any]
        let choice = body["decision"] as! [String: String]
        #expect(choice == ["_tag": "pairing-code", "access": "full-access", "code": "PAIR-1"])
        let file = folder.appendingPathComponent("token.json")
        let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! Int
        let folderMode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as! Int
        #expect(fileMode == 0o600 && folderMode == 0o700)
        let status = await link.status()
        #expect(status.connected && status.access == "full-access")
    }

    /// A token below Full access is revoked and not kept: T3 would refuse nudges to Full access threads.
    @Test func aNarrowerGrantIsRevokedAndNotSaved() async {
        let (link, t3, cli, folder) = setUp()
        t3.rtc = "approval-required"
        await #expect(throws: T3Link.Failure.self) { try await link.connect() }
        #expect(cli.commands.contains(["auth", "session", "revoke", "session-1"]))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("token.json").path))
    }

    @Test func sendCallsThreadSendWithTheNudgeAndItsRequestId() async throws {
        let (link, t3, _, _) = setUp()
        let result = await link.send(threadId: "th1", message: NudgePolicy.message(number: 1), requestId: "lighthouse-nudge-th1-100-1")
        #expect(result == .sent)
        let calls = t3.requests.filter { $0.path == "/mcp" }
        #expect(calls.count == 3)
        #expect(calls.allSatisfy { $0.headers["Authorization"]?.hasPrefix("Bearer ") == true })
        #expect(calls[1].headers["Mcp-Session-Id"] == "mcp-1" && calls[2].headers["Mcp-Session-Id"] == "mcp-1")
        let call = try JSONSerialization.jsonObject(with: calls[2].body!) as! [String: Any]
        let params = call["params"] as! [String: Any]
        #expect(params["name"] as? String == "t3_thread_send")
        let arguments = params["arguments"] as! [String: String]
        #expect(arguments == ["threadId": "th1", "message": NudgePolicy.message(number: 1), "mode": "auto", "clientRequestId": "lighthouse-nudge-th1-100-1"])
    }

    @Test func aRefusedSendIsAFailureWithT3sReason() async {
        let (link, t3, _, _) = setUp()
        t3.sendError = "runtime_mode_escalation_denied"
        let result = await link.send(threadId: "th1", message: "m", requestId: "r")
        #expect(result == .failed("T3 Code refused: runtime_mode_escalation_denied"))
        #expect(await link.status().lastError == "T3 Code refused: runtime_mode_escalation_denied")
    }

    @Test func aSavedTokenIsReusedUntilItNearlyExpires() async throws {
        let (link, t3, cli, _) = setUp()
        _ = try await link.connect()
        _ = await link.send(threadId: "th1", message: "m", requestId: "r")
        #expect(cli.commands.filter { $0.first == "auth" && $0[1] == "pairing" }.count == 1)
        // Two days before expiry it connects again, and revokes nothing (same fake session id).
        _ = await link.send(threadId: "th1", message: "m", requestId: "r", now: Date().addingTimeInterval(28 * 86400))
        #expect(cli.commands.filter { $0.first == "auth" && $0[1] == "pairing" }.count == 2)
        #expect(t3.requests.filter { $0.path == "/oauth/mcp/token" }.count == 2)
    }

    @Test func disconnectDeletesTheTokenAndRevokesItsSession() async throws {
        let (link, _, cli, folder) = setUp()
        _ = try await link.connect()
        await link.disconnect()
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("token.json").path))
        #expect(cli.commands.last == ["auth", "session", "revoke", "session-1"])
        #expect(await link.status().connected == false)
    }

    @Test func badThreadIdsAndForeignHostsAreRefused() async throws {
        let (link, t3, _, _) = setUp()
        #expect(await link.send(threadId: "a/b", message: "m", requestId: "r") == .failed("bad thread id"))
        #expect(await link.send(threadId: "x y", message: "m", requestId: "r") == .failed("bad thread id"))
        #expect(T3Link.validThreadId("thread:delegate%3Aabc:child.1_x-2"))
        #expect(t3.requests.isEmpty)
        #expect(T3Link.localPath("http://evil.example/oauth/mcp/token") == nil)
        #expect(T3Link.localPath("http://127.0.0.1:3773/oauth/mcp/token") == "/oauth/mcp/token")
        await #expect(throws: T3Link.Failure.self) {
            _ = try await LoopbackTransport().send(T3HTTPRequest(method: "GET", path: "@evil.example/x", headers: [:], body: nil))
        }
    }
}
