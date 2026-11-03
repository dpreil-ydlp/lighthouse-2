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
