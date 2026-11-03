import Foundation

/// "Waiting on you" from wording (SPEC 2.10): many agents finish a turn with a question or a request
/// for the owner's next step but raise no approval or input event. When a thread's turn has ended and
/// its last message is the agent's, that message is read locally and checked against fixed wording
/// rules. No model call, nothing sent; only the yes/no result is kept (`SessionThread.asksOwnerAt`),
/// never the text.
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

    /// The last `tailCharacters` of prose: fenced code and inline code removed.
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
        let trimmed = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.suffix(tailCharacters))
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

/// Reads each finished thread's last message once per change (keyed by thread id and last activity),
/// so an unchanged thread costs nothing on later passes.
public struct ReplyScanner: Sendable {
    private var cache: [String: (activity: Date, asks: Bool)] = [:]
    private let access: SourceAccess

    public init(access: SourceAccess = ReadOnlyFileSystem()) { self.access = access }

    /// Sets `asksOwnerAt` on finished, recent threads whose last agent message hands off to the owner.
    public mutating func mark(_ threads: [SessionThread], now: Date) -> [SessionThread] {
        var seen = Set<String>()
        let marked = threads.map { thread -> SessionThread in
            var thread = thread
            thread.asksOwnerAt = nil
            guard Self.eligible(thread, now: now) else { return thread }
            seen.insert(thread.id)
            let asks: Bool
            if let hit = cache[thread.id], hit.activity == thread.lastActivityAt {
                asks = hit.asks
            } else {
                asks = ReplyDetector.lastAgentMessage(paths: thread.transcriptPaths, access: access).map(ReplyDetector.asksOwner) ?? false
                cache[thread.id] = (thread.lastActivityAt, asks)
            }
            if asks { thread.asksOwnerAt = thread.lastActivityAt }
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
