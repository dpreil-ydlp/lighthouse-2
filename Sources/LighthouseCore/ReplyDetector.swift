import Foundation

/// "Waiting on you" without an approval or input event (SPEC 2.10). Many agents end a turn needing
/// the owner (a question, a choice, a task to do) but raise no event. With summaries on, the summary
/// model judges it from the conversation (`ThreadSummary.needsOwner`, see `ReplyJudgment`). With
/// summaries off, this fallback reads the agent's last message locally against fixed wording rules:
/// no model call, nothing sent. Either way only a yes/no is kept (`SessionThread.asksOwnerAt`).
public enum ReplyDetector {
    /// Only the end of the message counts: a question in the middle of a report is not a hand-off.
    static let tailCharacters = 600
    /// Older finished threads are not read.
    public static let window: TimeInterval = 48 * 3600
    /// Bytes read from the end of the newest transcript (the last message only is needed).
    static let readBudget = 256 * 1024

    /// True when the agent's last message hands the next step to the owner.
    public static func asksOwner(_ message: String) -> Bool {
        let tail = closingText(message)
        guard !tail.isEmpty else { return false }
        let lower = tail.lowercased()
        if closers.contains(where: { lower.range(of: $0, options: .regularExpression) != nil }) && !hasDirectAsk(lower) { return false }
        return hasDirectAsk(lower) || endsWithOwnerQuestion(tail)
    }

    /// The last paragraph of prose: fenced code, inline code and quoted text removed (a quoted
    /// example such as “Want me to push it?” is not a question to the owner).
    static func closingText(_ message: String) -> String {
        var text = message
        // Drop fenced blocks (an unclosed fence drops to the end).
        while let open = text.range(of: "```") {
            if let close = text.range(of: "```", range: open.upperBound..<text.endIndex) {
                text.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                text.removeSubrange(open.lowerBound..<text.endIndex)
            }
        }
        text = text.replacingOccurrences(of: "`[^`\n]*`", with: "code", options: .regularExpression)
        // Trailing bookkeeping (status footers, markup, client directives) comes after the real ending.
        var lines = text.components(separatedBy: .newlines)
        while let last = lines.last {
            let line = last.trimmingCharacters(in: .whitespaces)
            let footer = line.isEmpty || line.hasPrefix("<") || line.hasPrefix("::") || line.hasPrefix("[")
                || line.range(of: #"^(context (updated|unchanged)|commits?:)"#, options: [.regularExpression, .caseInsensitive]) != nil
            guard footer else { break }
            lines.removeLast()
        }
        var prose = lines.joined(separator: "\n")
        prose = prose.replacingOccurrences(of: #""[^"\n]{12,200}"|“[^”\n]{12,200}”"#, with: "a quote", options: .regularExpression)
        let paragraphs = prose.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return String((paragraphs.last ?? "").suffix(tailCharacters))
    }

    /// Requests that hand the next step to the owner, wherever they sit in the closing text.
    static let asks: [String] = [
        #"\b(should|shall|can|may) i\b[^.?!\n]*\?"#,
        #"\b(do|would) you (want|like|prefer)\b"#,
        #"\bwant me to\b"#,
        #"\b(are you|is it) (ok|okay|fine|alright) (with|if|to)\b"#,
        #"\b(ok|okay) to (proceed|continue|push|merge|deploy|ship|send|delete|run|go ahead)\b"#,
        #"\bwhich (one|option|approach|version|way)\b[^.?!\n]*\?"#,
        #"\bplease (confirm|approve|choose|pick|decide|reply|review|advise|let me know|tell me|use|click|press|open|send|paste|sign in|log in)\b"#,
        #"\b(i'?m |i am )?(waiting|awaiting) (for|on) (you|your)\b"#,
        #"\bneed(s)? (your|you to)\b"#,
        #"\b(needs?|with|after|until|get|on) your (call|decision|approval|go-ahead|input|confirmation|answer|ok|okay|yes)\b"#,
        #"\b(once|until|when) you (say|confirm|approve|decide|reply|choose|answer)\b"#,
        #"\b(say|reply) [*"“']*(go|yes|ok|okay|continue|approve)\b"#,
        #"\b(let me know|tell me) (which|whether|what|how|when|if (i|that|this|it's ok|it is ok))\b"#,
        #"\bblocked on (you|your)\b"#,
        #"\bover to you\b"#,
        #"\bshould we\b[^.?!\n]*\?"#,
    ]

    /// Polite closers that do not wait for anything.
    static let closers: [String] = [
        #"\blet me know if (you )?(have|need|want) (any )?(questions|anything|help|changes|more)"#,
        #"\btell me if you'?d rather\b"#,
        #"\b(tell me|let me know) if you want\b"#,
        #"\bhappy to help\b"#,
        #"\bfeel free to\b"#,
        #"\bif you('d| would) like,? i can\b"#,
    ]

    static func hasDirectAsk(_ lower: String) -> Bool {
        asks.contains { lower.range(of: $0, options: .regularExpression) != nil }
    }

    /// The closing text ends with a question addressed to the owner ("…you…?", "Ready?").
    static func endsWithOwnerQuestion(_ tail: String) -> Bool {
        let lines = tail.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let last = lines.last, last.hasSuffix("?") else { return false }
        let lower = last.lowercased()
        // A question quoted from elsewhere ("> …?") or a heading is not addressed to the owner.
        if lower.hasPrefix(">") || lower.hasPrefix("#") { return false }
        return lower.range(of: #"\b(you|your|we|i|me|ready|proceed|go ahead|ok|okay)\b"#, options: .regularExpression) != nil
    }

    /// The last message of the newest transcript, when it is the agent's (no owner message after it).
    public static func lastAgentMessage(paths: [String], access: SourceAccess) -> String? {
        guard let newest = paths.first else { return nil }
        let messages = TranscriptTail.messages(path: newest, access: access, budget: readBudget)
        guard let last = messages.last, last.role == "Assistant" else { return nil }
        return last.text
    }
}

/// The summary model's yes/no for a thread at one activity time.
public struct ReplyJudgment: Sendable, Hashable {
    public var activityAt: Date
    public var needsOwner: Bool
    public init(activityAt: Date, needsOwner: Bool) {
        self.activityAt = activityAt
        self.needsOwner = needsOwner
    }

    /// Judgments from stored summaries that carry one.
    public static func from(_ summaries: [String: ThreadSummary]) -> [String: ReplyJudgment] {
        summaries.compactMapValues { s in s.needsOwner.map { ReplyJudgment(activityAt: s.activityAt, needsOwner: $0) } }
    }
}

/// Marks finished threads that wait for the owner. `judgments` non-nil means summaries are on: only
/// the model's judgment for the thread's current activity counts (none yet means not marked). Nil
/// means summaries are off: the wording fallback reads each thread's last message once per change.
public struct ReplyScanner: Sendable {
    /// Per thread at one activity time and newest transcript: whether the agent spoke last, and the
    /// wording verdict.
    private var cache: [String: (activity: Date, path: String?, agentLast: Bool, asks: Bool)] = [:]
    private let access: SourceAccess

    public init(access: SourceAccess = ReadOnlyFileSystem()) { self.access = access }

    /// Sets `asksOwnerAt` on finished, recent threads whose last agent message hands off to the owner.
    public mutating func mark(_ threads: [SessionThread], now: Date, judgments: [String: ReplyJudgment]? = nil) -> [SessionThread] {
        var seen = Set<String>()
        let marked = threads.map { thread -> SessionThread in
            var thread = thread
            thread.asksOwnerAt = nil
            guard Self.eligible(thread, now: now) else { return thread }
            seen.insert(thread.id)
            let read: (agentLast: Bool, asks: Bool)
            if let hit = cache[thread.id], hit.activity == thread.lastActivityAt, hit.path == thread.transcriptPaths.first {
                read = (hit.agentLast, hit.asks)
            } else {
                let message = ReplyDetector.lastAgentMessage(paths: thread.transcriptPaths, access: access)
                read = (message != nil, message.map(ReplyDetector.asksOwner) ?? false)
                cache[thread.id] = (thread.lastActivityAt, thread.transcriptPaths.first, read.agentLast, read.asks)
            }
            // The owner wrote last: the next move is the agent's, whatever the model said.
            guard read.agentLast else { return thread }
            let waits: Bool
            if let judgments {
                guard let judgment = judgments[thread.id], judgment.activityAt >= thread.lastActivityAt else { return thread }
                waits = judgment.needsOwner
            } else {
                waits = read.asks
            }
            if waits { thread.asksOwnerAt = thread.lastActivityAt }
            return thread
        }
        cache = cache.filter { seen.contains($0.key) }
        return marked
    }

    /// The turn has ended (not running, no T3 request open) and the thread is recent.
    static func eligible(_ thread: SessionThread, now: Date) -> Bool {
        guard thread.state != .running, thread.state != .waitingForOwner, thread.pendingRequest == nil,
              !thread.transcriptPaths.isEmpty else { return false }
        return now.timeIntervalSince(thread.lastActivityAt) < ReplyDetector.window
    }
}
