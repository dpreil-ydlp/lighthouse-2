import Foundation
import Testing
@testable import LighthouseCore

/// Opt-in live check of SPEC 2.11 on a test Mac: skipped unless `LIGHTHOUSE_LIVE_NUDGE_THREAD` names
/// a scratch T3 thread. Connects to the running T3 Code with the real flow (t3 pairing code, OAuth,
/// Full access), sends nudge 1 into that thread, then disconnects (revokes the session, deletes the
/// token). The token lives in a temp folder only and is never printed.
@Suite struct LiveNudgeProbe {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIGHTHOUSE_LIVE_NUDGE_THREAD"] != nil))
    func liveNudge() async throws {
        let thread = ProcessInfo.processInfo.environment["LIGHTHOUSE_LIVE_NUDGE_THREAD"]!
        let scratch = Scratch()
        let folder = scratch.url.appendingPathComponent("t3")
        let link = T3Link(folder: folder)
        let token = try await link.connect()
        let mode = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("token.json").path)[.posixPermissions] as! Int
        print("LIVE nudge connect access=\(token.access) session=\(token.sessionId != nil) daysLeft=\(Int(token.expiresAt.timeIntervalSinceNow / 86400)) fileMode=\(String(mode, radix: 8))")
        let run = "probe\(Int(Date().timeIntervalSince1970))"
        let result = await link.send(threadId: thread, message: NudgePolicy.message(number: 1),
                                     requestId: NudgePolicy.requestId(threadId: thread, episodeKey: run, number: 1))
        print("LIVE nudge send result=\(result)")
        await link.disconnect()
        print("LIVE nudge disconnect tokenFile=\(FileManager.default.fileExists(atPath: folder.appendingPathComponent("token.json").path))")
        #expect(token.access == "full-access")
        #expect(result == .sent)
    }
}
