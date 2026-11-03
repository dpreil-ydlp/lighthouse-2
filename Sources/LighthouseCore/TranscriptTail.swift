import Foundation

/// Bounded, read-only tail of a thread's conversation for one summary request (M8, SPEC 2.9 §4).
///
/// Reads at most `readBudget` bytes from the end of each transcript through `SourceAccess` (stat and
/// `pread` only), keeps user and assistant **text** only, and returns at most the last
/// `maxTextBytes` of it after redaction. Tool calls, tool output, file contents, thinking, images,
/// injected context and system records are skipped. The result lives in memory for one request; it
/// is never stored or logged.
public enum TranscriptTail {
    /// Contract M8: the tail is the last 24 KB of user and assistant text.
    public static let maxTextBytes = 24 * 1024
    /// Bytes read from the end of one file.
    public static let readBudget = 2 << 20
    /// Lines longer than this are skipped unread (same bound as ingestion, SPEC §3.1).
    static let maxLine = 1 << 20
    /// Text gathered before redaction, so a secret at the cut point is still recognised whole.
    static let gatherBytes = maxTextBytes + 8 * 1024

    public struct Message: Sendable, Hashable {
        public var role: String
        public var text: String
    }

    /// The redacted tail of the newest transcripts, oldest message first; nil when nothing readable
    /// remains or redaction ran past its budget.
    public static func read(paths: [String], access: SourceAccess) -> String? {
        guard let raw = gather(paths: paths, access: access) else { return nil }
        return finish(raw, deadline: Date().addingTimeInterval(Redactor.budget))
    }

    /// The raw (unredacted) messages behind the tail, oldest first: whole messages up to `gatherBytes`
    /// (the last one may be longer, up to `maxLine`). Never sent as is: see `finish`.
    public static func gather(paths: [String], access: SourceAccess) -> String? {
        var newestFirst: [Message] = []
        var gathered = 0
        for path in paths where gathered < gatherBytes {
            let messages = messages(path: path, access: access)
            for message in messages.reversed() where gathered < gatherBytes {
                newestFirst.append(message)
                gathered += message.text.utf8.count + 16
            }
        }
        guard !newestFirst.isEmpty else { return nil }
        return newestFirst.reversed().map { "\($0.role): \($0.text)" }.joined(separator: "\n\n")
    }

    /// Redacts the gathered text, then keeps its last `maxTextBytes`; nil when redaction ran past
    /// `deadline` (the caller then sends nothing, M8-E03).
    public static func finish(_ raw: String, deadline: Date) -> String? {
        guard let redacted = Redactor.redact(raw, deadline: deadline) else { return nil }
        return keepLast(redacted, bytes: maxTextBytes)
    }

    /// User and assistant text messages from the last `readBudget` bytes of one file, in file order.
    public static func messages(path: String, access: SourceAccess, budget: Int = readBudget) -> [Message] {
        guard let stat = access.stat(path), !stat.isDirectory, !stat.isSymlink, stat.size > 0 else { return [] }
        let start = stat.size > UInt64(budget) ? stat.size - UInt64(budget) : 0
        guard let data = access.read(path, offset: start, count: Int(stat.size - start)) else { return [] }
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        // A read that starts mid-file begins inside a line; drop that fragment.
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        var result: [Message] = []
        for line in lines where line.count <= maxLine {
            if let message = message(Data(line)) { result.append(message) }
        }
        return result
    }

    /// One record → one message, for Claude Code and Codex transcript formats.
    static func message(_ line: Data) -> Message? {
        let claude = LineScan.contains(line, "\"type\":\"user\"") || LineScan.contains(line, "\"type\":\"assistant\"")
        let codex = LineScan.contains(line, "\"type\":\"response_item\"")
        guard claude || codex,
              let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return nil }
        if codex, object["type"] as? String == "response_item" { return codexMessage(object) }
        return claudeMessage(object)
    }

    /// Claude Code: `user`/`assistant` records; text blocks only. Tool results, meta records and
    /// sidechains are skipped.
    static func claudeMessage(_ object: [String: Any]) -> Message? {
        guard let type = object["type"] as? String, type == "user" || type == "assistant" else { return nil }
        if object["isMeta"] as? Bool == true || object["isSidechain"] as? Bool == true || object["toolUseResult"] != nil { return nil }
        guard let message = object["message"] as? [String: Any] else { return nil }
        var texts: [String] = []
        if let content = message["content"] as? String {
            texts = [content]
        } else if let blocks = message["content"] as? [[String: Any]] {
            // A user record that carries a tool result is tool output, even if it also has text.
            if blocks.contains(where: { $0["type"] as? String == "tool_result" }) { return nil }
            texts = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        }
        let text = texts.map { type == "user" ? userText($0) : $0 }.map(trimmed).filter { !$0.isEmpty }.joined(separator: "\n")
        guard !text.isEmpty else { return nil }
        return Message(role: type == "user" ? "User" : "Assistant", text: text)
    }

    /// Codex: `response_item` messages with role user or assistant; `input_text`/`output_text` only.
    static func codexMessage(_ object: [String: Any]) -> Message? {
        guard let payload = object["payload"] as? [String: Any], payload["type"] as? String == "message",
              let role = payload["role"] as? String, role == "user" || role == "assistant",
              let blocks = payload["content"] as? [[String: Any]] else { return nil }
        let texts = blocks.compactMap { block -> String? in
            guard let kind = block["type"] as? String, kind == "input_text" || kind == "output_text" else { return nil }
            return block["text"] as? String
        }
        let text = texts.map { role == "user" ? userText($0) : $0 }.map(trimmed).filter { !$0.isEmpty }.joined(separator: "\n")
        guard !text.isEmpty else { return nil }
        return Message(role: role == "user" ? "User" : "Assistant", text: text)
    }

    /// Text the owner typed. Context the client injects into user turns (environment blocks,
    /// AGENTS.md, system reminders, command echoes) is not conversation and is dropped.
    static func userText(_ text: String) -> String {
        var text = text
        while let open = text.range(of: "<system-reminder>") {
            guard let close = text.range(of: "</system-reminder>", range: open.upperBound..<text.endIndex) else {
                text.removeSubrange(open.lowerBound..<text.endIndex)
                break
            }
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }
        let head = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let injected = ["<environment_context", "<user_instructions", "<permissions", "<turn_aborted", "<command-", "<local-command-",
                        "<user-prompt-submit-hook", "<subagent_notification", "# AGENTS.md instructions", "Caveat: The messages below"]
        if injected.contains(where: { head.hasPrefix($0) }) { return "" }
        return head
    }

    static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The last `bytes` of UTF-8 text, cut at a character boundary.
    static func keepLast(_ text: String, bytes: Int) -> String {
        let utf8 = Array(text.utf8)
        guard utf8.count > bytes else { return text }
        var start = utf8.count - bytes
        while start < utf8.count, utf8[start] & 0xC0 == 0x80 { start += 1 }
        return String(decoding: utf8[start...], as: UTF8.self)
    }
}
