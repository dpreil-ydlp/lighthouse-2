import Foundation
import Testing
@testable import LighthouseCore

/// M10: the main-page "what's happening" line.
@Suite struct HeadlineTests {
    let now = Fixture.date("2026-10-29T12:00:00.000Z")

    func thread(_ id: String, state: ThreadState, minutesAgo: Double, title: String) -> SessionThread {
        SessionThread(id: "codex:\(id)", owningApp: .codex, providerIdentities: [ProviderIdentity(provider: .codex, nativeId: id)],
                      title: title, cwd: "/x", state: state, sourceReadAt: now, lastActivityAt: now.addingTimeInterval(-minutesAgo * 60))
    }

    func project(_ threads: [SessionThread], attention: [String] = []) -> ProjectSummary {
        let identity = ProjectIdentity(root: "/P/demo", name: "demo", kind: .git)
        return ShelfBuilder.summarize(threads: threads, identities: Array(repeating: identity, count: threads.count),
                                      attention: attention.isEmpty ? [:] : [identity.root: attention], now: now)[0]
    }

    func summary(_ threadId: String, _ text: String) -> ThreadSummary {
        ThreadSummary(threadId: threadId, line1: text, line2: nil, madeAt: now, activityAt: now, inputHash: "h", provider: .claude, model: "m")
    }

    @Test func titleWhenNoSummary() {
        let p = project([thread("a", state: .idle, minutesAgo: 1, title: "Fix login redirect")])
        #expect(p.status == .recent)
        #expect(ProjectHeadline.make(for: p) { _ in nil } == ProjectHeadline(threadId: "codex:a", text: "Fix login redirect", isSummary: false))
    }

    @Test func summaryWinsOverTitle() {
        let p = project([thread("a", state: .running, minutesAgo: 1, title: "Fix login redirect")])
        let h = ProjectHeadline.make(for: p) { self.summary($0.id, "Patched the redirect; running tests") }
        #expect(h == ProjectHeadline(threadId: "codex:a", text: "Patched the redirect; running tests", isSummary: true))
    }

    @Test func runningThreadBeatsMoreRecentIdle() {
        let p = project([thread("idle", state: .idle, minutesAgo: 0, title: "Old chat"),
                         thread("run", state: .running, minutesAgo: 3, title: "Build the release")])
        #expect(ProjectHeadline.make(for: p) { _ in nil }?.text == "Build the release")
    }

    /// Nearest wrong result: a needs-you project headlined by a running thread instead of the waiting one.
    @Test func needsYouPicksWaitingThread() {
        let p = project([thread("run", state: .running, minutesAgo: 1, title: "Busy worker"),
                         thread("ask", state: .waitingForOwner, minutesAgo: 5, title: "Asks to approve deploy")],
                        attention: ["Approval requested"])
        #expect(p.status == .needsYou)
        #expect(ProjectHeadline.make(for: p) { _ in nil }?.text == "Asks to approve deploy")
    }

    @Test func quietProjectHasNoHeadline() {
        let p = project([thread("a", state: .idle, minutesAgo: 60, title: "Yesterday's work")])
        #expect(p.status == .quiet)
        #expect(ProjectHeadline.make(for: p) { _ in nil } == nil)
    }

    @Test func emptySummaryFallsBackToTitle() {
        let p = project([thread("a", state: .idle, minutesAgo: 1, title: "Fix login redirect")])
        #expect(ProjectHeadline.make(for: p) { self.summary($0.id, "") }?.isSummary == false)
    }
}
