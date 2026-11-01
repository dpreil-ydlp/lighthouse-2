import Foundation
import Testing
@testable import LighthouseCore

/// Opt-in live probe for the SPEC §11 M2(1) comparison. Skipped unless `LIGHTHOUSE_LIVE_CODEX_USAGE=1`.
/// Reads `~/.codex/auth.json` in place (no Keychain, no prompt, no window), makes one HTTPS GET to
/// the Codex usage endpoint, and prints only percents, resets, plan and the account alias.
@Suite struct LiveUsageProbe {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIGHTHOUSE_LIVE_CODEX_USAGE"] == "1"))
    func codexLiveReading() async {
        let monitor = UsageMonitor(providers: [.codex: .init(adapter: CodexUsageAdapter(), credentials: CodexAuthFile())],
                                   transport: HTTPSUsageTransport())
        let now = Date()
        let reading = await monitor.poll(.codex, now: now)!
        var lines = ["LIVE codex at=\(ISO8601DateFormatter().string(from: now)) status=\(reading.status) plan=\(reading.plan ?? "-") alias=\(reading.accountAlias ?? "-")"]
        for w in reading.windows {
            lines.append("LIVE codex window=\(w.id) used=\(w.usedPercent) resets=\(w.resetsAt.map { ISO8601DateFormatter().string(from: $0) } ?? "-") duration=\(w.duration.map { String(Int($0)) } ?? "-")")
        }
        print(lines.joined(separator: "\n"))
        #expect(reading.status == .fresh)
    }
}
