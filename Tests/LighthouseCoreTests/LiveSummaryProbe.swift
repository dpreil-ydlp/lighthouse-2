import Foundation
import Testing
@testable import LighthouseCore

/// Opt-in live check for M8 C2 and C6. Skipped unless `LIGHTHOUSE_LIVE_SUMMARY=claude|chatgpt`.
///
/// Runs the real `SummaryService` with the real CLI runner on one **synthetic** transcript (never the
/// user's conversations), with a temporary store and an empty scratch folder. The canary is read
/// from `LIGHTHOUSE_LIVE_CANARY_FILE` (made by the receipt script) so it never appears in a command
/// line. Prints the argv the service ran, exit code, timing, request size, the stored summary, and
/// canary counts for the store, its WAL, the scratch folder and the temp folder. One live call per run.
@Suite struct LiveSummaryProbe {
    /// Wraps the real launcher; remembers only whether the request held the canary.
    final class Tee: SummaryProcessLauncher, @unchecked Sendable {
        let inner = SystemProcessLauncher()
        let canary: Data
        private let lock = NSLock()
        private(set) var sawCanary = false
        private(set) var command: SummaryCommand?
        init(canary: Data) { self.canary = canary }
        func run(_ command: SummaryCommand, input: Data, timeout: TimeInterval) async -> ProcessOutcome {
            lock.withLock {
                sawCanary = input.range(of: canary) != nil
                self.command = command
            }
            return await inner.run(command, input: input, timeout: timeout)
        }
    }

    static func transcript(provider: SummaryProvider, canary: String) -> String {
        func json(_ object: [String: Any]) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self) }
        let turns: [(String, String)] = [
            ("user", "The invoice export button on the billing page times out for accounts with more than 500 invoices. Can you fix it? Internal note \(canary)."),
            ("assistant", "The export loads every invoice into memory before writing the CSV. I am changing it to stream rows in pages of 100."),
            ("user", "Keep the column order the same as before, finance relies on it."),
            ("assistant", "Done: streaming export with the original column order. Now adding a test with 1,200 invoices and checking the download still starts within two seconds."),
        ]
        switch provider {
        case .chatgpt:
            var lines = [json(["timestamp": "2026-11-01T09:00:00.000Z", "type": "session_meta", "payload": ["id": "synthetic", "cwd": "/synthetic/billing"]])]
            for (role, text) in turns {
                lines.append(json(["timestamp": "2026-11-01T09:01:00.000Z", "type": "response_item",
                                   "payload": ["type": "message", "role": role, "content": [["type": role == "user" ? "input_text" : "output_text", "text": text]]]]))
            }
            lines.append(json(["timestamp": "2026-11-01T09:02:00.000Z", "type": "response_item",
                               "payload": ["type": "function_call_output", "output": "TOOL OUTPUT \(canary) must not be sent"]]))
            return lines.joined(separator: "\n") + "\n"
        default:
            var lines: [String] = []
            for (role, text) in turns {
                lines.append(json(["type": role, "sessionId": "synthetic", "cwd": "/synthetic/billing", "timestamp": "2026-11-01T09:01:00.000Z",
                                   "message": ["role": role, "content": role == "user" ? text as Any : [["type": "text", "text": text]] as Any]]))
            }
            lines.append(json(["type": "user", "toolUseResult": ["stdout": "x"], "timestamp": "2026-11-01T09:02:00.000Z",
                               "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t", "content": "TOOL OUTPUT \(canary)"]]]]))
            return lines.joined(separator: "\n") + "\n"
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIGHTHOUSE_LIVE_SUMMARY"] != nil))
    func liveSummaryOfASyntheticThread() async throws {
        let env = ProcessInfo.processInfo.environment
        let provider = try #require(SummaryProvider(rawValue: env["LIGHTHOUSE_LIVE_SUMMARY"] ?? ""))
        let canaryFile = try #require(env["LIGHTHOUSE_LIVE_CANARY_FILE"])
        let canary = try String(contentsOfFile: canaryFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(canary.count >= 16)
        let scratchFolder = try #require(env["LIGHTHOUSE_LIVE_SCRATCH"])
        let s = Scratch()
        let transcript = s.write("synthetic/transcript.jsonl", Self.transcript(provider: provider, canary: canary))
        let storeDir = s.url.appendingPathComponent("AppSupport/Lighthouse")
        let store = try Store(url: storeDir.appendingPathComponent("lighthouse.sqlite"))
        let tee = Tee(canary: Data(canary.utf8))
        let settings = SummarySettings(provider: provider)
        let service = SummaryService(settings: settings, store: store, launcher: tee, scratch: scratchFolder)
        let candidate = SummaryCandidate(threadId: "synthetic:billing-export", title: "Invoice export timeout", projectName: "billing",
                                         state: .running, lastActivityAt: Date().addingTimeInterval(-90), transcriptPaths: [transcript])
        let report = try #require(await service.step([candidate]))
        let command = try #require(tee.command)
        print("LIVE summary provider=\(provider.rawValue) model=\(settings.model ?? "-") cli=\(command.executable)")
        print("LIVE summary argv=\(Self.quoted([command.executable] + command.arguments))")
        print("LIVE summary cwd=\(command.directory) env-keys=\(command.environment.keys.sorted().joined(separator: ","))")
        print(String(format: "LIVE summary outcome=%@ called=%@ exit=%@ seconds=%.2f requestBytes=%d stdoutBytes=%d stderrBytes=%d",
                     report.outcome.rawValue, "\(report.called)", report.exitCode.map(String.init) ?? "none", report.seconds,
                     report.requestBytes, report.stdoutBytes, report.stderrBytes))
        let stored = store.loadSummaries()[candidate.threadId]
        print("LIVE summary stored line1=\(stored?.line1 ?? "<none>")")
        print("LIVE summary stored line2=\(stored?.line2 ?? "<none>")")
        print("LIVE summary stored line1Chars=\(stored?.line1.count ?? 0) hash=\(stored?.inputHash ?? "-") model=\(stored?.model ?? "-")")
        #expect(report.outcome == .made)
        #expect((stored?.line1.count ?? 99) <= 90)

        // C6: the canary is in the request and nowhere Lighthouse wrote.
        print("LIVE canary inRequest=\(tee.sawCanary)")
        let scratchEntries = (try? FileManager.default.contentsOfDirectory(atPath: scratchFolder)) ?? []
        print("LIVE scratch entriesAfterCall=\(scratchEntries.count)")
        func hits(_ dir: String) -> (files: Int, withCanary: Int) {
            let files = (FileManager.default.enumerator(atPath: dir)?.allObjects as? [String] ?? []).map { (dir as NSString).appendingPathComponent($0) }
            return (files.count, files.filter { bytesContain($0, canary) }.count)
        }
        let before = hits(storeDir.path)
        store.checkpointWAL()
        let after = hits(storeDir.path)
        let temp = (try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory()))?.filter { $0.lowercased().hasPrefix("lighthouse") } ?? []
        let tempHits = temp.filter { bytesContain((NSTemporaryDirectory() as NSString).appendingPathComponent($0), canary) }.count
        print("LIVE canary store files=\(before.files) withCanary=\(before.withCanary) afterCheckpoint withCanary=\(after.withCanary) scratch withCanary=\(hits(scratchFolder).withCanary) tempLighthouseFiles=\(temp.count) withCanary=\(tempHits) summaryHasCanary=\((stored?.line1 ?? "").contains(canary) || (stored?.line2 ?? "").contains(canary))")
        #expect(tee.sawCanary)
        #expect(before.withCanary == 0 && after.withCanary == 0 && tempHits == 0)
        #expect(scratchEntries.isEmpty)
    }

    static func quoted(_ argv: [String]) -> String {
        argv.map { $0.isEmpty ? "''" : ($0.contains(where: { " \"'".contains($0) }) ? "'\($0.replacingOccurrences(of: "'", with: "'\\''"))'" : $0) }
            .joined(separator: " ")
    }
}

/// Opt-in M8 C7 probe. Skipped unless `LIGHTHOUSE_LIVE_SUMMARY_IDLE=<seconds>`. The M7 idle loop
/// (`LiveT3IdleProbe`: real sources, a pass every 10 s, a full pass every 60 s) with summaries **on**:
/// after each resolve the summary scheduler runs, exactly as the app does. The launcher only records
/// (no CLI starts) and the transcript source returns a fixed line without reading any file, so none
/// of the user's conversation text is read or sent. Every thread is marked summarized at its
/// activity when the window starts; a later would-be call therefore means that thread changed.
@Suite struct LiveSummaryIdleProbe {
    struct NoRead: TranscriptSource {
        func tail(paths: [String]) -> String? { "User: (probe: no file read)" }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIGHTHOUSE_LIVE_SUMMARY_IDLE"] != nil))
    func liveLoopCPUWithSummariesOn() async throws {
        let duration = Double(ProcessInfo.processInfo.environment["LIGHTHOUSE_LIVE_SUMMARY_IDLE"] ?? "600") ?? 600
        let engine = Engine(collectors: [ClaudeCodeCollector(), CodexCollector()], store: nil, t3: T3Collector())
        _ = await engine.indexToCompletion()
        let h = Harness()
        let launcher = FakeLauncher()
        let service = SummaryService(settings: SummarySettings(provider: .claude), store: nil, transcripts: NoRead(), launcher: launcher,
                                     locator: h.locator, scratch: h.scratch, home: h.base.path)
        var snapshot = await engine.resolvedSnapshot()
        let start = Date()
        var lastSeen: [String: Date] = [:]
        for candidate in SummaryCandidate.from(snapshot.projects) {
            await service.seed(ThreadSummary(threadId: candidate.threadId, line1: "seed", line2: nil, madeAt: start, activityAt: candidate.lastActivityAt,
                                             inputHash: "seed", provider: .claude, model: SummarySettings.defaultClaudeModel))
            lastSeen[candidate.threadId] = candidate.lastActivityAt
        }
        let eligibleAtStart = SummaryCandidate.from(snapshot.projects).filter { SummaryRules.isEligible($0, now: start) }.count
        let cpuStart = LiveT3Probe.cpuSeconds()
        var lastFull = Date()
        var passes = 0, steps = 0, stepCPU = 0.0
        var changed = Set<String>()
        var calledIds: [String] = []
        while Date().timeIntervalSince(start) < duration {
            try await Task.sleep(for: .seconds(10))
            let full = Date().timeIntervalSince(lastFull) >= 60
            let before = await engine.changeCount
            _ = await engine.pass(scope: full ? .full : .paths([]), resolve: false)
            passes += 1
            if full { lastFull = Date() }
            guard await engine.changeCount != before || full else { continue }
            snapshot = await engine.resolvedSnapshot()
            let candidates = SummaryCandidate.from(snapshot.projects)
            for c in candidates where c.lastActivityAt > (lastSeen[c.threadId] ?? .distantPast) { changed.insert(c.threadId); lastSeen[c.threadId] = c.lastActivityAt }
            let t0 = LiveComponentProbe.times()
            while let report = await service.step(candidates) {
                steps += 1
                if report.called { calledIds.append(report.threadId) }
            }
            let t1 = LiveComponentProbe.times()
            stepCPU += t1.user + t1.system - t0.user - t0.system
        }
        let wall = Date().timeIntervalSince(start)
        let cpu = LiveT3Probe.cpuSeconds() - cpuStart
        let unchangedCalls = calledIds.filter { !changed.contains($0) }.count
        print(String(format: "LIVE summaryIdle wall=%.0f s cpu=%.2f s avg=%.2f %% passes=%d schedulerCPU=%.3f s threads=%d eligibleAtStart=%d",
                     wall, cpu, 100 * cpu / wall, passes, stepCPU, SummaryCandidate.from(snapshot.projects).count, eligibleAtStart))
        print("LIVE summaryIdle processesStarted=0 wouldBeCalls=\(launcher.count) steps=\(steps) threadsThatChanged=\(changed.count) callsForUnchangedThreads=\(unchangedCalls)")
        #expect(unchangedCalls == 0)
    }
}
