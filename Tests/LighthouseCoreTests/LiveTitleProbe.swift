import Foundation
import Testing
@testable import LighthouseCore

/// Opt-in live probe for M4-R08: skipped unless `LIGHTHOUSE_LIVE_TITLES=1` (optional
/// `LIGHTHOUSE_LIVE_TITLES_PROJECT`, the project folder to print). Reads the
/// local sources in place (T3 read-only through the production reader, no store) and prints, for
/// that project's newest 20 T3 threads (parents and nested subagents), the title from T3's title
/// field, the row Lighthouse shows, and the parent nesting. Titles and ids only; no message bodies.
@Suite struct LiveTitleProbe {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIGHTHOUSE_LIVE_TITLES"] == "1"))
    func liveT3TitlesAndNesting() async throws {
        guard let wanted = ProcessInfo.processInfo.environment["LIGHTHOUSE_LIVE_TITLES_PROJECT"] else {
            print("LIVE set LIGHTHOUSE_LIVE_TITLES_PROJECT to a project folder")
            return
        }
        // LIGHTHOUSE_LIVE_TITLES_NO_T3=1 runs without the T3 source, as test mode does.
        let noT3 = ProcessInfo.processInfo.environment["LIGHTHOUSE_LIVE_TITLES_NO_T3"] == "1"
        let engine = Engine(collectors: [ClaudeCodeCollector(), CodexCollector()], store: nil, t3: noT3 ? nil : T3Collector(),
                            t3NotRead: noT3 ? "Not read in test mode" : nil)
        let snapshot = await engine.indexToCompletion()
        let state = try T3Reader().read().get()
        let t3Status = snapshot.statuses.first { $0.source == .t3 }
        var lines = ["LIVE configuration: \(noT3 ? "no T3 source (as in test mode)" : "normal (T3 read in place, read-only)")", "LIVE t3 status error=\(t3Status?.error ?? "none") lastRead=\(t3Status.map { "\($0.lastReadAt)" } ?? "nil")"]
        guard let project = snapshot.projects.first(where: { $0.identity.root.lowercased() == wanted.lowercased() }) else {
            print((lines + ["LIVE project not found: \(wanted)"]).joined(separator: "\n"))
            return
        }
        let rows = project.threads
        let fallback = rows.filter { $0.title == nil || $0.title?.isEmpty == true }
        lines.append("LIVE project root=\(project.identity.root) rows=\(rows.count) t3Rows=\(rows.filter { $0.t3ThreadId != nil }.count) fallbackTitleRows=\(fallback.count) t3OwnedFallbackRows=\(fallback.filter { $0.owningApp == .t3 }.count) nestedT3Subagents=\(rows.reduce(0) { $0 + $1.subagents.filter { $0.t3ThreadId != nil }.count })")
        let primary = project.mostRecentThread
        lines.append("LIVE open targets: \"\(primary?.displayTitle ?? "-")\" owner=\(primary?.owningApp.rawValue ?? "-")")

        // Newest 20 T3 threads of this project, from T3 itself, and where Lighthouse shows each.
        let projectIds = Set(state.projects.filter { $0.root.lowercased() == wanted.lowercased() }.map(\.id))
        let byId = Dictionary(state.threads.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let newest = state.threads.filter { projectIds.contains($0.projectId) }
            .sorted { (state.runs[$0.id]?.requestedAt ?? $0.createdAt ?? .distantPast) > (state.runs[$1.id]?.requestedAt ?? $1.createdAt ?? .distantPast) }
            .prefix(20)
        var shownParent: [String: (String, String)] = [:]
        for row in rows {
            for sub in row.subagents { if let t = sub.t3ThreadId { shownParent[t] = (row.id, sub.name) } }
        }
        for thread in newest {
            let parent = thread.lineageParent ?? state.subagents.first { $0.childThreadId == thread.id }?.parentThreadId
            let shown: String
            if let row = rows.first(where: { $0.t3ThreadId == thread.id }) {
                shown = "top-level row title=\"\(row.displayTitle)\""
            } else if let (parentRow, name) = shownParent[thread.id] {
                shown = "nested under \(parentRow) as \"\(name)\""
            } else {
                shown = "not shown"
            }
            lines.append("LIVE t3 thread id=\(thread.id) t3Title=\"\(thread.title)\" parent=\(parent.map { "\($0) (\"\(byId[$0]?.title ?? "?")\")" } ?? "none") run=\(state.runs[thread.id]?.status ?? "none") -> \(shown)")
        }
        for row in fallback.filter({ $0.owningApp == .t3 }).prefix(5) {
            lines.append("LIVE fallback t3-owned row id=\(row.id) title=\"\(row.displayTitle)\" t3ThreadId=\(row.t3ThreadId ?? "nil")")
        }
        print(lines.joined(separator: "\n"))
    }
}
