import Foundation
import Testing
@testable import LighthouseCore

/// SPEC 2.10: a finished turn whose last agent message hands the next step to the owner is "Needs you".
@Suite struct ReplyDetectorTests {
    @Test(arguments: [
        "Tests pass and the branch is ready. Want me to push it and open the PR?",
        "I found two ways to fix this:\n1. Patch the parser\n2. Replace it\nWhich option do you prefer?",
        "The migration is written. Should I run it against staging?",
        "Done with the draft. Please review it and confirm before I send it.",
        "I'm blocked on your API key for the sandbox account.",
        "Deploy is staged. Waiting for your go-ahead.",
        "Let me know which mailbox to use and I'll continue.",
        "Everything is built. Do you want me to release 0.0.7 now?",
        "Is it okay to delete the old branch?",
        "Ready to merge when you are. Shall I go ahead?",
        "Two cards are left. Copy the notes to the shared folder? Say \"go\" for both and I'll do it.",
        "The server isn't ordered yet and won't be until you say go.",
        "Next I'll retry the test label, then switch on real labels with your OK.",
        "Sign-in failed with an error, so please use **Continue** on the consent screen.",
        "Should I delete the old folder?\n\nContext updated: Decisions (archive location).",
        "Steps 1 and 2 need your yes before I start.",
    ])
    func asks(_ message: String) {
        #expect(ReplyDetector.asksOwner(message), "\(message)")
    }

    @Test(arguments: [
        "Fixed the crash in the parser. All 260 tests pass and the release is installed.",
        "Done. Let me know if you have any questions.",
        "Released 0.0.6 and installed it on both Macs. Tell me if you'd rather use red.",
        "The question was: why does the build fail? It failed because the cache was stale. Fixed now.",
        "Added the check:\n```swift\nif ready { print(\"Should I continue?\") }\n```\nThe test passes.",
        "## Why does this happen?\nThe cache was stale; I cleared it and the build passes.",
        "Any config change the reviewer suggests waits for your approval.",
        "Not reviewed yet. Tell me if you want a review before you share it.\n\nContext unchanged: status only.",
        "Released 0.0.7 and installed it on both Macs.\n\nExamples that now count: “Want me to push it?” and “I won't order it until you say go”.\n\nTo go back, run the installer with the old version.",
        "The release is done and installed. If you want to try it, open the panel.",
        "Weekly row added.\n\n<oai-mem-citation>\n<citation_entries>\nx\n</citation_entries>\n</oai-mem-citation>",
        "",
    ])
    func doesNotAsk(_ message: String) {
        #expect(!ReplyDetector.asksOwner(message), "\(message)")
    }

    /// A question early in a long report is not a hand-off; only the closing text counts.
    @Test func onlyTheClosingTextCounts() {
        let report = "Should I keep the old API? I decided to keep it for now.\n\n" + String(repeating: "Details of the change. ", count: 60) + "All done."
        #expect(!ReplyDetector.asksOwner(report))
    }

    func line(_ role: String, _ text: String) -> String {
        let object: [String: Any] = ["type": role, "message": ["role": role, "content": [["type": "text", "text": text]]]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    func thread(path: String, state: ThreadState, minutesAgo: Double, now: Date) -> SessionThread {
        var thread = SessionThread(id: "claude:r1", owningApp: .claudeCode, providerIdentities: [ProviderIdentity(provider: .claude, nativeId: "r1")],
                                   title: "Release", cwd: "/x", state: state, sourceReadAt: now, lastActivityAt: now.addingTimeInterval(-minutesAgo * 60))
        thread.transcriptPaths = [path]
        return thread
    }

    @Test func finishedThreadEndingOnAQuestionNeedsYou() {
        let scratch = Scratch()
        let now = Date()
        let path = scratch.write("s.jsonl", [line("user", "release it"), line("assistant", "Built and tested. Want me to push it?")].joined(separator: "\n") + "\n")
        var scanner = ReplyScanner()
        let marked = scanner.mark([thread(path: path, state: .idle, minutesAgo: 3, now: now)], now: now)
        #expect(marked[0].asksOwnerAt != nil)
        let items = AttentionRules.items(for: marked[0], now: now)
        #expect(items.count == 1)
        #expect(items[0].kind == .waitingForOwner)
        #expect(items[0].label == "Reply needed · Release")
        let identity = ProjectIdentity(root: "/P/rel", name: "rel", kind: .git)
        let project = ShelfBuilder.summarize(threads: marked, identities: [identity], now: now)[0]
        #expect(project.status == .needsYou)
        #expect(project.waitingItems.count == 1)
    }

    /// The owner answered after the question: the last message is the owner's, so nothing waits.
    @Test func ownerReplyClearsIt() {
        let scratch = Scratch()
        let now = Date()
        let path = scratch.write("s.jsonl", [line("assistant", "Want me to push it?"), line("user", "yes")].joined(separator: "\n") + "\n")
        var scanner = ReplyScanner()
        #expect(scanner.mark([thread(path: path, state: .idle, minutesAgo: 1, now: now)], now: now)[0].asksOwnerAt == nil)
    }

    /// While the turn runs, or after the window, the transcript is not read for this.
    @Test func runningAndOldThreadsAreNotMarked() {
        let scratch = Scratch()
        let now = Date()
        let path = scratch.write("s.jsonl", line("assistant", "Want me to push it?") + "\n")
        var scanner = ReplyScanner()
        #expect(scanner.mark([thread(path: path, state: .running, minutesAgo: 1, now: now)], now: now)[0].asksOwnerAt == nil)
        #expect(scanner.mark([thread(path: path, state: .stopped, minutesAgo: 49 * 60, now: now)], now: now)[0].asksOwnerAt == nil)
        #expect(scanner.mark([thread(path: path, state: .stopped, minutesAgo: 30, now: now)], now: now)[0].asksOwnerAt != nil)
    }

    /// With summaries on, only the model's judgment for the current activity counts (SPEC 2.10).
    @Test func modelJudgmentReplacesTheWordingRules() {
        let scratch = Scratch()
        let now = Date()
        let path = scratch.write("s.jsonl", line("assistant", "Want me to push it?") + "\n")
        let t = thread(path: path, state: .idle, minutesAgo: 5, now: now)
        var scanner = ReplyScanner()
        // Model says no: not marked, even though the wording asks.
        #expect(scanner.mark([t], now: now, judgments: [t.id: ReplyJudgment(activityAt: t.lastActivityAt, needsOwner: false)])[0].asksOwnerAt == nil)
        // No judgment yet: not marked (no wording guess while the model is on).
        #expect(scanner.mark([t], now: now, judgments: [:])[0].asksOwnerAt == nil)
        // A judgment from before the latest activity does not count.
        #expect(scanner.mark([t], now: now, judgments: [t.id: ReplyJudgment(activityAt: t.lastActivityAt.addingTimeInterval(-60), needsOwner: true)])[0].asksOwnerAt == nil)
        // Model says yes for this activity: marked, whatever the wording.
        let done = thread(path: scratch.write("d.jsonl", line("assistant", "Sign-in page is open.") + "\n"), state: .idle, minutesAgo: 5, now: now)
        #expect(scanner.mark([done], now: now, judgments: [done.id: ReplyJudgment(activityAt: done.lastActivityAt, needsOwner: true)])[0].asksOwnerAt != nil)
        // The owner wrote last: not marked, even when the model says yes.
        let answered = thread(path: scratch.write("o.jsonl", [line("assistant", "Want me to push it?"), line("user", "yes")].joined(separator: "\n") + "\n"),
                              state: .idle, minutesAgo: 5, now: now)
        #expect(scanner.mark([answered], now: now, judgments: [answered.id: ReplyJudgment(activityAt: answered.lastActivityAt, needsOwner: true)])[0].asksOwnerAt == nil)
        // Running threads are never marked.
        let running = thread(path: path, state: .running, minutesAgo: 1, now: now)
        #expect(scanner.mark([running], now: now, judgments: [running.id: ReplyJudgment(activityAt: running.lastActivityAt, needsOwner: true)])[0].asksOwnerAt == nil)
    }

    /// Codex transcripts count too.
    @Test func codexAssistantMessage() {
        let scratch = Scratch()
        let now = Date()
        let object: [String: Any] = ["type": "response_item", "payload": ["type": "message", "role": "assistant",
                                                                         "content": [["type": "output_text", "text": "Which approach should I take?"]]]]
        let path = scratch.write("c.jsonl", String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n")
        var scanner = ReplyScanner()
        #expect(scanner.mark([thread(path: path, state: .idle, minutesAgo: 2, now: now)], now: now)[0].asksOwnerAt != nil)
    }
}

/// Expanded rows list every thread that needs the owner first (owner 2026-11-03).
@Suite struct WaitingExpansionTests {
    let now = Date()

    func thread(_ id: String, _ state: ThreadState, minutesAgo: Double, asks: Bool = false) -> SessionThread {
        var t = SessionThread(id: "claude:\(id)", owningApp: .claudeCode, providerIdentities: [ProviderIdentity(provider: .claude, nativeId: id)],
                              title: "T\(id)", cwd: "/x", state: state, sourceReadAt: now, lastActivityAt: now.addingTimeInterval(-minutesAgo * 60))
        if asks { t.asksOwnerAt = t.lastActivityAt }
        return t
    }

    @Test func waitingThreadsComeFirstThenLiveOnes() {
        let threads = [thread("run", .running, minutesAgo: 1), thread("a", .idle, minutesAgo: 2), thread("b", .idle, minutesAgo: 3),
                       thread("w1", .idle, minutesAgo: 30, asks: true), thread("w2", .stopped, minutesAgo: 90, asks: true)]
        let identity = ProjectIdentity(root: "unassigned:/x", name: "No project", kind: .unassigned)
        let project = ShelfBuilder.summarize(threads: threads, identities: Array(repeating: identity, count: threads.count), now: now)[0]
        // Oldest wait first; a stopped thread that waits is listed too.
        #expect(project.waitingThreads.map(\.id) == ["claude:w2", "claude:w1"])
        #expect(project.expansionThreads(limit: 3).map(\.id) == ["claude:w2", "claude:w1", "claude:run"])
        // More waiting threads than the limit: all of them are shown.
        #expect(project.expansionThreads(limit: 1).map(\.id) == ["claude:w2", "claude:w1"])
        // Nothing waiting: the usual first live threads.
        let quiet = ShelfBuilder.summarize(threads: Array(threads.prefix(3)), identities: Array(repeating: identity, count: 3), now: now)[0]
        #expect(quiet.expansionThreads(limit: 3).map(\.id) == quiet.liveThreads.prefix(3).map(\.id))
    }
}
