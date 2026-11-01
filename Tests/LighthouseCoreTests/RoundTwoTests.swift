import Foundation
import Testing
@testable import LighthouseCore

/// M1-01 round 2: the launch shelf comes from stored checkpoints with no source I/O.
@Suite struct RoundTwoTests {
    @Test func restoredSnapshotReadsNoSourceAndIsNotFresh() async throws {
        let s = Scratch()
        s.installFixtures()
        let dbURL = s.url.appendingPathComponent("db/lighthouse.sqlite")
        let store = try Store(url: dbURL)
        let readAt = Fixture.date("2026-10-29T10:06:00.000Z")
        let first = Engine(collectors: [ClaudeCodeCollector(root: s.claudeRoot, store: store), CodexCollector(codexHome: s.codexHome, store: store)],
                           store: store, home: s.path)
        let indexed = await first.pass(now: readAt)

        // Relaunch: new collectors over the same store, with an access recorder.
        let access = RecordingAccess()
        let reopened = try Store(url: dbURL)
        let second = Engine(collectors: [ClaudeCodeCollector(root: s.claudeRoot, access: access, store: reopened),
                                         CodexCollector(codexHome: s.codexHome, access: access, store: reopened)],
                            store: reopened, home: s.path)
        let later = readAt.addingTimeInterval(10 * 60)
        let restored = await second.restoredSnapshot(now: later)

        #expect(access.operations.isEmpty)
        #expect(restored.checkedAt == nil)
        #expect(Set(restored.projects.flatMap(\.threads).map(\.id)) == Set(indexed.projects.flatMap(\.threads).map(\.id)))
        // Last successful read is 10 min old (> 5 min stale bound): nothing restored looks live.
        let threads = restored.projects.flatMap(\.threads)
        #expect(threads.allSatisfy { $0.state == .unknown && $0.sourceReadAt == readAt })
        #expect(!restored.projects.contains { $0.status == .working })
    }
}
