import Foundation
import Testing
@testable import LighthouseCore

/// Opt-in live probe for M4 noise: skipped unless `LIGHTHOUSE_LIVE_ATTENTION=1`. Indexes the local
/// machine's real sources in place (no store, T3 read-only) and prints only counts and ages of attention
/// items and running threads by owning app; no title, path or id.
@Suite struct LiveAttentionProbe {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIGHTHOUSE_LIVE_ATTENTION"] == "1"))
    func liveAttentionCounts() async throws {
        let engine = Engine(collectors: [ClaudeCodeCollector(), CodexCollector()], store: nil, t3: T3Collector())
        let snapshot = await engine.indexToCompletion()
        let now = Date()
        let threads = snapshot.projects.flatMap(\.threads)
        let items = snapshot.projects.flatMap(\.attentionItems)
        var lines: [String] = []
        for app in OwningApp.allCases {
            let running = threads.filter { $0.owningApp == app && $0.state == .running }
            let unknownCoverage = running.filter { AttentionRules.stallNote(for: $0) == "Coverage unknown" }.count
            let ages = running.compactMap { AttentionRules.progressReference(of: $0) }.map { Int(now.timeIntervalSince($0) / 60) }.sorted()
            lines.append("LIVE running owner=\(app.rawValue) count=\(running.count) coverageUnknown=\(unknownCoverage) minutesSinceProgress=\(ages)")
        }
        for kind in [AttentionKind.waitingForOwner, .stalledThread, .silentSubagent] {
            let matching = items.filter { $0.kind == kind }
            let ages = matching.map { Int(now.timeIntervalSince($0.enteredAt) / 60) }.sorted()
            lines.append("LIVE items kind=\(kind.rawValue) count=\(matching.count) minutesSinceEntered=\(ages)")
        }
        for thread in threads where thread.owningApp == .t3 && thread.state == .running {
            func m(_ d: Date?) -> String { d.map { String(Int(now.timeIntervalSince($0) / 60)) } ?? "nil" }
            lines.append("LIVE t3 running: runStartMin=\(m(thread.runningSince)) progressMin=\(m(thread.lastProgressAt)) activityMin=\(m(thread.latestActivityAt)) aliases=\(thread.aliasIds.map { $0.split(separator: ":").first.map(String.init) ?? "?" }) subagents=\(thread.subagents.count) runningSubagents=\(thread.subagents.filter { $0.state == .running }.count)")
        }
        if let state = try? T3Reader().read().get() {
            for thread in threads where thread.owningApp == .t3 && thread.state == .running {
                guard let id = thread.t3ThreadId, let run = state.runs[id] else { continue }
                let rows = state.subagents.filter { $0.parentThreadId == id }
                let rowStatus = Dictionary(grouping: rows, by: \.status).mapValues(\.count)
                let lineageKids = state.threads.filter { $0.lineageParent == id }.map(\.id)
                let kidRuns = Dictionary(grouping: lineageKids.compactMap { state.runs[$0]?.status }, by: { $0 }).mapValues(\.count)
                let requests = state.pendingRequests.filter { $0.threadId == id }.map(\.kind)
                lines.append("LIVE t3 run status=\(run.status) subagentRows=\(rowStatus) lineageChildRuns=\(kidRuns) pendingKinds=\(requests)")
            }
            let active = state.runs.values.filter { StateRules.t3ActiveRuns.contains($0.status) }
            lines.append("LIVE t3 active runs total=\(active.count) statuses=\(Dictionary(grouping: active, by: \.status).mapValues(\.count))")
        }
        lines.append("LIVE projects=\(snapshot.projects.count) threads=\(threads.count) needsYou=\(snapshot.projects.filter { $0.status == .needsYou }.count) errors=\(snapshot.statuses.filter { $0.error != nil }.map(\.source.rawValue))")
        print(lines.joined(separator: "\n"))
    }
}
