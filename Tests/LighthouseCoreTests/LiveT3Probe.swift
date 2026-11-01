import Foundation
import SQLite3
import Testing
@testable import LighthouseCore

/// Opt-in live probe for SPEC §11 M3(4) (§3.2 T3 deadline and budgets). Skipped unless
/// `LIGHTHOUSE_LIVE_T3=1`. Reads the local `~/.t3/userdata/statev2.sqlite` in place through the
/// production reader (read-only, no copy), then one full engine pass over the real JSONL sources
/// with no store. Prints only timings, counts and file modes; no title, path or id.
@Suite struct LiveT3Probe {
    /// User + system CPU time of this process.
    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }

    /// Current and peak `phys_footprint` of this process in bytes (Activity Monitor "Memory", M7 C3).
    static func footprint() -> (current: UInt64, peak: UInt64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        return (info.phys_footprint, UInt64(info.ledger_phys_footprint_peak))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIGHTHOUSE_LIVE_T3"] == "1"))
    func liveT3ReadAndMerge() async throws {
        let userdata = NSHomeDirectory() + "/.t3/userdata"
        let entriesBefore = Set((try? FileManager.default.contentsOfDirectory(atPath: userdata)) ?? [])
        var reader = T3Reader()
        let modes = OpenModes()
        let databasePath = reader.databasePath
        reader.whileOpen = { modes.capture(pid: getpid(), matching: databasePath) }
        var seconds: [Double] = []
        var cpu: [Double] = []
        var state: T3State?
        for index in 0..<6 {
            // The first read captures file modes with lsof; the timed reads run without the hook.
            if index == 1 { reader.whileOpen = nil }
            let start = DispatchTime.now().uptimeNanoseconds
            let cpuStart = Self.cpuSeconds()
            let result = reader.read()
            cpu.append(Self.cpuSeconds() - cpuStart)
            seconds.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
            state = try result.get()
            if index == 0 { seconds.removeAll(); cpu.removeAll() }
        }
        let s = try #require(state)
        var lines = [String(format: "LIVE t3 read seconds min=%.3f max=%.3f deadline=%.0f; cpu seconds per read min=%.3f max=%.3f",
                            seconds.min()!, seconds.max()!, T3Reader.deadline, cpu.min()!, cpu.max()!)]
        lines.append("LIVE t3 counts projects=\(s.projects.count) threads=\(s.threads.count) mappings=\(s.providerThreads.count) runs=\(s.runs.count) pending=\(s.pendingRequests.count) subagentRows=\(s.subagents.count) environmentId=\(s.environmentId != nil)")
        lines.append("LIVE t3 open modes=\(modes.files.map { ($0.key as NSString).lastPathComponent + ":" + $0.value }.sorted())")

        let engine = Engine(collectors: [ClaudeCodeCollector(), CodexCollector()], store: nil, t3: T3Collector())
        let started = Date()
        let snapshot = await engine.indexToCompletion()
        let indexSeconds = Date().timeIntervalSince(started)
        let threads = snapshot.projects.flatMap(\.threads)
        let t3Threads = threads.filter { $0.t3ThreadId != nil }
        let passStart = DispatchTime.now().uptimeNanoseconds
        _ = await engine.pass(now: Date().addingTimeInterval(T3Collector.defaultMinInterval + 1))
        let passSeconds = Double(DispatchTime.now().uptimeNanoseconds - passStart) / 1e9
        let t3PassSeconds = await engine.t3?.lastSeconds ?? -1
        lines.append(String(format: "LIVE engine index seconds=%.1f; live full pass seconds=%.2f (t3 read %.3f)", indexSeconds, passSeconds, t3PassSeconds))
        lines.append("LIVE merge projects=\(snapshot.projects.count) threads=\(threads.count) t3Parents=\(t3Threads.count) t3WithAliases=\(t3Threads.filter { !$0.aliasIds.isEmpty }.count) aliases=\(t3Threads.reduce(0) { $0 + $1.aliasIds.count }) t3Subagents=\(t3Threads.reduce(0) { $0 + $1.subagents.filter { $0.t3ThreadId != nil }.count }) t3Projects=\(snapshot.projects.filter { $0.identity.kind == .t3 }.count)")
        let items = snapshot.projects.flatMap(\.attentionItems)
        lines.append("LIVE attention waiting=\(items.filter { $0.kind == .waitingForOwner }.count) silent=\(items.filter { $0.kind == .silentSubagent }.count) t3Error=\(snapshot.statuses.first { $0.source == .t3 }?.error ?? "none")")
        let fallbackClaudeTitles = threads.filter { $0.owningApp == .t3 && $0.displayTitle.hasPrefix("Claude Code session ·") }.count
        lines.append("LIVE t3-owned threads with fallback Claude title=\(fallbackClaudeTitles)")
        // Every native id appears in at most one row (aliases are never listed twice).
        let natives = threads.flatMap { $0.providerIdentities } + threads.flatMap(\.subagents).flatMap { $0.nativeIds.map { ProviderIdentity(provider: .codex, nativeId: $0) } }
        let duplicateParents = Dictionary(grouping: threads.flatMap(\.providerIdentities), by: { $0 }).filter { $0.value.count > 1 }.count
        lines.append("LIVE duplicate parent identities=\(duplicateParents) identities=\(natives.count)")
        print(lines.joined(separator: "\n"))

        let entriesAfter = Set((try? FileManager.default.contentsOfDirectory(atPath: userdata)) ?? [])
        #expect(entriesAfter == entriesBefore)
        #expect(seconds.max()! < T3Reader.deadline)
        #expect(modes.files.count == 3 && modes.files.values.allSatisfy { $0 == "r" })
        #expect(duplicateParents == 0)
    }
}

/// Opt-in headless proxy for the §3.2 idle budget with T3 polling (SPEC §11 M3(4)). Skipped unless
/// `LIGHTHOUSE_LIVE_T3_IDLE=<seconds>`. Runs the app's live-loop cadence without UI: a pass every
/// 10 s (full rescan every 60 s, T3 throttled to 60 s), resolving only when something changed.
/// Prints CPU percent of this process, its peak resident memory and its `phys_footprint` (after
/// indexing, the highest sampled after each idle pass, and the kernel's peak over the whole run).
/// No store, no UI, no window.
@Suite struct LiveT3IdleProbe {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIGHTHOUSE_LIVE_T3_IDLE"] != nil))
    func liveLoopCPUWithT3() async throws {
        let duration = Double(ProcessInfo.processInfo.environment["LIGHTHOUSE_LIVE_T3_IDLE"] ?? "600") ?? 600
        let engine = Engine(collectors: [ClaudeCodeCollector(), CodexCollector()], store: nil, t3: T3Collector())
        _ = await engine.indexToCompletion()
        let indexedFootprint = LiveT3Probe.footprint().current
        var idleFootprint: UInt64 = 0
        let cpuStart = LiveT3Probe.cpuSeconds()
        let started = Date()
        var lastFull = Date()
        var passes = 0, resolves = 0, t3Reads = 0, t3MaxSeconds = 0.0
        var lastT3 = await engine.t3?.lastSeconds
        var fullCPU = 0.0, pathsCPU = 0.0, t3PassCPU = 0.0, resolveCPU = 0.0, idleBytes = 0
        let splitStart = LiveComponentProbe.times()
        while Date().timeIntervalSince(started) < duration {
            try await Task.sleep(for: .seconds(10))
            let full = Date().timeIntervalSince(lastFull) >= 60
            let before = await engine.changeCount
            let bytesBefore = await engine.bytesReadTotal
            let passStart = LiveComponentProbe.times()
            _ = await engine.pass(scope: full ? .full : .paths([]), resolve: false)
            let passEnd = LiveComponentProbe.times()
            let t3Read = await engine.t3?.lastSeconds
            if full { fullCPU += passEnd.user + passEnd.system - passStart.user - passStart.system } else { pathsCPU += passEnd.user + passEnd.system - passStart.user - passStart.system }
            if let t3Read, t3Read != lastT3 { t3PassCPU += passEnd.user + passEnd.system - passStart.user - passStart.system }
            idleBytes += await engine.bytesReadTotal - bytesBefore
            passes += 1
            if full { lastFull = Date() }
            if await engine.changeCount != before || full {
                let resolveStart = LiveComponentProbe.times()
                _ = await engine.resolvedSnapshot(); resolves += 1
                let resolveEnd = LiveComponentProbe.times()
                resolveCPU += resolveEnd.user + resolveEnd.system - resolveStart.user - resolveStart.system
            }
            let t3 = await engine.t3?.lastSeconds
            if let t3, t3 != lastT3 { t3Reads += 1; t3MaxSeconds = max(t3MaxSeconds, t3); lastT3 = t3 }
            idleFootprint = max(idleFootprint, LiveT3Probe.footprint().current)
        }
        let wall = Date().timeIntervalSince(started)
        let cpu = LiveT3Probe.cpuSeconds() - cpuStart
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        print(String(format: "LIVE idle wall=%.0f s cpu=%.2f s avg=%.2f %% maxRSS=%.0f MB passes=%d resolves=%d t3Reads=%d t3MaxRead=%.3f s",
                     wall, cpu, 100 * cpu / wall, Double(usage.ru_maxrss) / 1_048_576, passes, resolves, t3Reads, t3MaxSeconds))
        let splitEnd = LiveComponentProbe.times()
        let total = splitEnd.user + splitEnd.system - splitStart.user - splitStart.system
        print(String(format: "LIVE split user=%.2f s system=%.2f s fullPasses=%.2f s passesWithT3Read=%.2f s (inside full or FSEvents passes) fsEventPasses=%.2f s resolves=%.2f s other=%.2f s newBytes=%d",
                     splitEnd.user - splitStart.user, splitEnd.system - splitStart.system, fullCPU, t3PassCPU, pathsCPU, resolveCPU,
                     total - fullCPU - pathsCPU - resolveCPU, idleBytes))
        let footprint = LiveT3Probe.footprint()
        print(String(format: "LIVE footprint afterIndex=%.1f MB idleMax=%.1f MB end=%.1f MB peak=%.1f MB",
                     Double(indexedFootprint) / 1_048_576, Double(idleFootprint) / 1_048_576,
                     Double(footprint.current) / 1_048_576, Double(footprint.peak) / 1_048_576))
    }
}

/// Opt-in CPU attribution for M7 C1. Skipped unless `LIGHTHOUSE_LIVE_COMPONENTS=<repeats>`. After
/// indexing the local machine's real sources (no store), times each live-loop component in its steady state:
/// a full rescan per JSONL collector, an FSEvents pass with no changed path, a T3 SQLite read, a
/// stat-confirmed T3 skip, and a resolve. Prints user and system CPU per call; no title, path or id.
@Suite struct LiveComponentProbe {
    static func times() -> (user: Double, system: Double) {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return (Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6,
                Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6)
    }

    static func measure(_ label: String, repeats: Int, _ body: () async -> Void) async -> String {
        let before = times()
        let started = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<repeats { await body() }
        let after = times()
        let wall = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9 / Double(repeats)
        let user = (after.user - before.user) / Double(repeats), system = (after.system - before.system) / Double(repeats)
        return String(format: "LIVE component %@ user=%.4f s system=%.4f s total=%.4f s wall=%.4f s per call (n=%d)",
                      label, user, system, user + system, wall, repeats)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIGHTHOUSE_LIVE_COMPONENTS"] != nil))
    func liveComponentCPU() async throws {
        let repeats = Int(ProcessInfo.processInfo.environment["LIGHTHOUSE_LIVE_COMPONENTS"] ?? "10") ?? 10
        let claude = ClaudeCodeCollector(), codex = CodexCollector()
        let t3 = T3Collector()
        let engine = Engine(collectors: [claude, codex], store: nil, t3: t3)
        _ = await engine.indexToCompletion()
        var lines: [String] = []
        let codexFiles = await codex.pass(now: Date(), scope: .full).status
        let claudeFiles = await claude.pass(now: Date(), scope: .full).status
        lines.append("LIVE component files codexInWindow=\(codexFiles.filesInWindow) codexNotIndexed=\(codexFiles.filesNotIndexed) claudeInWindow=\(claudeFiles.filesInWindow) claudeNotIndexed=\(claudeFiles.filesNotIndexed)")
        lines.append(await Self.measure("codexFullRescan", repeats: repeats) { _ = await codex.pass(now: Date(), scope: .full) })
        lines.append(await Self.measure("claudeFullRescan", repeats: repeats) { _ = await claude.pass(now: Date(), scope: .full) })
        lines.append(await Self.measure("codexPathsPass", repeats: repeats) { _ = await codex.pass(now: Date(), scope: .paths([])) })
        lines.append(await Self.measure("claudePathsPass", repeats: repeats) { _ = await claude.pass(now: Date(), scope: .paths([])) })
        let reader = t3.reader
        if case .success(let state) = reader.read() {
            let lengths = state.threads.map(\.id.utf8.count)
            lines.append("LIVE component t3 threads=\(lengths.count) idBytes avg=\(lengths.reduce(0, +) / max(1, lengths.count)) max=\(lengths.max() ?? 0) subagentRows=\(state.subagents.count)")
        }
        lines.append(await Self.measure("t3SqliteRead", repeats: repeats) { _ = reader.read() })
        // Per-statement cost, on a connection opened exactly like the reader's (read-only, in place).
        var db: OpaquePointer?
        if sqlite3_open_v2(T3Reader.uri(reader.databasePath), &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOFOLLOW | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db {
            let connection = T3Reader.Connection(db: db, expired: { false })
            try connection.exec("PRAGMA query_only = ON")
            for (index, query) in T3Reader.queries.enumerated() {
                var rows = 0
                lines.append(await Self.measure("t3Query\(index)", repeats: repeats) {
                    rows = 0
                    try? connection.exec("BEGIN")
                    try? connection.rows(query) { _ in rows += 1 }
                    try? connection.exec("ROLLBACK")
                } + " rows=\(rows)")
            }
        }
        sqlite3_close_v2(db)
        lines.append(await Self.measure("t3StatSkip", repeats: repeats) { _ = reader.fileStamps(); _ = reader.preflight() })
        lines.append(await Self.measure("resolve", repeats: repeats) { _ = await engine.resolvedSnapshot() })
        // Each call is more than 60 s after the last, so the project resolver is rebuilt (git and folder lookups).
        var later = Date()
        lines.append(await Self.measure("resolveWithResolverRebuild", repeats: repeats) {
            later = later.addingTimeInterval(61)
            _ = await engine.resolvedSnapshot(now: later)
        })
        print(lines.joined(separator: "\n"))
    }
}
