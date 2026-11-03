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
            let tail = showText ? " | " + String((message.map(ReplyDetector.closingText) ?? "<owner spoke last>").suffix(140)).replacingOccurrences(of: "\n", with: " ") : ""
            print("LIVE reply asks=\(asks) app=\(thread.owningApp.rawValue) min=\(Int(now.timeIntervalSince(thread.lastActivityAt) / 60)) title=\(thread.displayTitle.prefix(50))\(tail)")
        }
        print("LIVE reply total yes=\(yes) no=\(no)")
    }
}
