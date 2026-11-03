import Foundation
import Testing
@testable import LighthouseCore

/// Opt-in live probe for SPEC 2.10: skipped unless `LIGHTHOUSE_LIVE_REPLY=1`. Indexes the local
/// machine's real sources in place (no store, T3 read-only) and prints, for each finished thread in
/// the reply window, its owning app, age and the detector's yes/no. Output goes to the terminal only.
@Suite struct LiveReplyProbe {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIGHTHOUSE_LIVE_REPLY"] == "1"))
    func liveReplies() async throws {
        let engine = Engine(collectors: [ClaudeCodeCollector(), CodexCollector()], store: nil, t3: T3Collector())
        let snapshot = await engine.indexToCompletion()
        let now = Date()
        let access = ReadOnlyFileSystem()
        let showText = ProcessInfo.processInfo.environment["LIGHTHOUSE_LIVE_REPLY_TEXT"] == "1"
        var yes = 0, no = 0
        for thread in snapshot.projects.flatMap(\.threads) where ReplyScanner.eligible(thread, now: now) {
            let message = ReplyDetector.lastAgentMessage(paths: thread.transcriptPaths, access: access)
            let asks = message.map(ReplyDetector.asksOwner) ?? false
            if asks { yes += 1 } else { no += 1 }
            let raw = ProcessInfo.processInfo.environment["LIGHTHOUSE_LIVE_REPLY_RAW"] == "1"
            let shown = raw ? message.map { String($0.suffix(900)) } : message.map(ReplyDetector.closingText).map { String($0.suffix(140)) }
            let tail = showText ? " | " + (shown ?? "<owner spoke last>").replacingOccurrences(of: "\n", with: " ") : ""
            print("LIVE reply asks=\(asks) app=\(thread.owningApp.rawValue) min=\(Int(now.timeIntervalSince(thread.lastActivityAt) / 60)) title=\(thread.displayTitle.prefix(50))\(tail)")
        }
        print("LIVE reply total yes=\(yes) no=\(no)")
    }
}

/// Opt-in live check of the model judgment (SPEC 2.10): skipped unless `LIGHTHOUSE_LIVE_REPLY_MODEL=1`.
/// Uses the real summary path (CLI, redaction, temporary store, empty scratch folder) on the local
/// machine's finished threads: every thread the wording rules flag plus the most recent others, at
/// most `LIGHTHOUSE_LIVE_REPLY_MAX` (default 14) calls. Prints title, wording verdict and model
/// verdict only; the summary text and transcript are not printed.
@Suite struct LiveReplyModelProbe {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIGHTHOUSE_LIVE_REPLY_MODEL"] == "1"))
    func liveModelJudgments() async throws {
        let env = ProcessInfo.processInfo.environment
        let limit = Int(env["LIGHTHOUSE_LIVE_REPLY_MAX"] ?? "") ?? 14
        let engine = Engine(collectors: [ClaudeCodeCollector(), CodexCollector()], store: nil, t3: T3Collector())
        let snapshot = await engine.indexToCompletion()
        let now = Date()
        let access = ReadOnlyFileSystem()
        var rows: [(SessionThread, String, Bool)] = []
        for project in snapshot.projects {
            for thread in project.threads where ReplyScanner.eligible(thread, now: now) {
                let asks = ReplyDetector.lastAgentMessage(paths: thread.transcriptPaths, access: access).map(ReplyDetector.asksOwner) ?? false
                rows.append((thread, project.identity.name, asks))
            }
        }
        let flagged = rows.filter(\.2)
        let others = rows.filter { !$0.2 }.sorted { $0.0.lastActivityAt > $1.0.lastActivityAt }
        let picked = Array((flagged + others).prefix(limit))
        let s = Scratch()
        let store = try Store(url: s.url.appendingPathComponent("store/lighthouse.sqlite"))
        let scratch = s.dir("cli-scratch")
        let service = SummaryService(settings: SummarySettings(provider: .claude), store: store, scratch: scratch)
        for (thread, project, asks) in picked {
            let candidate = SummaryCandidate(threadId: thread.id, title: thread.displayTitle, projectName: project, state: thread.state,
                                             lastActivityAt: now.addingTimeInterval(-90), transcriptPaths: thread.transcriptPaths)
            let report = await service.step([candidate], now: now)
            let judged = store.loadSummaries()[thread.id]?.needsOwner
            print("LIVE model words=\(asks ? "yes" : "no ") model=\(judged.map { $0 ? "yes" : "no " } ?? "-  ") outcome=\(report?.outcome.rawValue ?? "none") min=\(Int(now.timeIntervalSince(thread.lastActivityAt) / 60)) title=\(thread.displayTitle.prefix(50))")
        }
    }
}
