import Foundation

/// Ingestion bounds (SPEC §3.1).
public struct IngestLimits: Sendable, Hashable {
    public var maxBytesPerPass: Int
    public var maxLineBytes: Int
    /// First-run window: files last modified earlier are listed as "not indexed".
    public var indexWindow: TimeInterval

    public init(maxBytesPerPass: Int = 4 << 20, maxLineBytes: Int = 1 << 20, indexWindow: TimeInterval = 30 * 24 * 60 * 60) {
        self.maxBytesPerPass = maxBytesPerPass
        self.maxLineBytes = maxLineBytes
        self.indexWindow = indexWindow
    }

    public static let standard = IngestLimits()
}

/// Per-file checkpoint (SPEC §3.1): device + inode, size, byte offset, mtime, plus the derived
/// metadata accumulated so far. Persisted after each pass so restart resumes at `offset`.
public struct FileCheckpoint<State: Codable & Sendable>: Codable, Sendable {
    public var path: String
    public var device: UInt64
    public var inode: UInt64
    public var size: UInt64
    public var offset: UInt64
    public var mtime: Double
    public var skippedLines: Int
    /// True while the reader is inside an over-long line; bytes up to the next newline are discarded.
    public var skippingLine: Bool
    public var state: State
    /// Bytes after `offset` held back as an incomplete trailing line in the last pass (not persisted).
    public var deferredBytes: UInt64 = 0
    /// Time of the last successful read or readability check of this file (persisted).
    public var lastReadAt: Double?
    /// Why the last attempt failed; nil after a successful read (persisted, shown as coverage).
    public var readError: String?

    /// The last attempt failed; the file is retried on the next full pass.
    public var unreadable: Bool { readError != nil }

    /// Nothing more can be read until the file changes.
    public var isCaughtUp: Bool { unreadable || offset + deferredBytes >= size }

    enum CodingKeys: String, CodingKey { case path, device, inode, size, offset, mtime, skippedLines, skippingLine, state, lastReadAt, readError }

    public init(path: String, device: UInt64, inode: UInt64, size: UInt64, offset: UInt64, mtime: Double,
                skippedLines: Int, skippingLine: Bool, state: State, lastReadAt: Double? = nil, readError: String? = nil) {
        self.path = path
        self.device = device
        self.inode = inode
        self.size = size
        self.offset = offset
        self.mtime = mtime
        self.skippedLines = skippedLines
        self.skippingLine = skippingLine
        self.state = state
        self.lastReadAt = lastReadAt
        self.readError = readError
    }
}

/// Result of one bounded read.
struct ReadOutcome {
    var bytesRead: Int
    var linesHandled: Int
    var reset: Bool
}

enum JSONLTail {
    /// Bytes per read inside one pass (see `advance`).
    static let sliceBytes = 256 << 10

    /// Advances `checkpoint` by at most `limits.maxBytesPerPass` bytes, calling `handle` for each
    /// complete line no longer than `limits.maxLineBytes`. Longer lines are skipped and counted; an
    /// incomplete trailing line is left for the next pass. Truncation or a new inode resets to 0 and
    /// calls `reset` so derived state is replaced.
    ///
    /// A failed open or read records `readError` and leaves `lastReadAt` at the last success, so a
    /// failing source never looks freshly read (SPEC §2 V-TRUTH).
    static func advance<S>(
        _ checkpoint: inout FileCheckpoint<S>,
        stat: FileStat,
        access: SourceAccess,
        limits: IngestLimits,
        now: Date,
        sliceBytes: Int = JSONLTail.sliceBytes,
        reset: (inout S) -> Void,
        handle: (Data, inout S) -> Void
    ) -> ReadOutcome {
        guard access.isReadable(checkpoint.path) else {
            checkpoint.readError = "Cannot open for reading"
            return ReadOutcome(bytesRead: 0, linesHandled: 0, reset: false)
        }
        var didReset = false
        if stat.inode != checkpoint.inode || stat.device != checkpoint.device || stat.size < checkpoint.offset {
            checkpoint.offset = 0
            checkpoint.skippedLines = 0
            checkpoint.skippingLine = false
            checkpoint.device = stat.device
            checkpoint.inode = stat.inode
            reset(&checkpoint.state)
            didReset = true
        }
        checkpoint.size = stat.size
        checkpoint.mtime = stat.mtime
        checkpoint.deferredBytes = 0
        guard stat.size > checkpoint.offset else {
            checkpoint.readError = nil
            checkpoint.lastReadAt = now.timeIntervalSince1970
            return ReadOutcome(bytesRead: 0, linesHandled: 0, reset: didReset)
        }

        let want = Int(min(UInt64(limits.maxBytesPerPass), stat.size - checkpoint.offset))
        // The pass reads up to `want` bytes in slices, keeping only the unfinished line between them,
        // so memory per file is one slice plus one line (≤ maxLineBytes), not the whole 4 MB budget.
        // Lines, skips and offsets are those of a single read of `want` bytes (M7 C3).
        let before = checkpoint
        var buffer = Data()
        var dropped = 0          // bytes of the current line not kept (it is already too long, or skipped)
        var readTotal = 0
        var consumed = 0         // bytes through the last newline seen
        var lines = 0
        while readTotal < want {
            let count = min(sliceBytes, want - readTotal)
            guard let part = access.read(checkpoint.path, offset: checkpoint.offset + UInt64(readTotal), count: count) else {
                checkpoint = before
                checkpoint.readError = "Read failed"
                return ReadOutcome(bytesRead: 0, linesHandled: 0, reset: didReset)
            }
            if part.isEmpty { break }
            let bufferStart = readTotal - buffer.count   // file position (relative to offset) of buffer[0]
            buffer.append(part)
            readTotal += part.count
            var lineStart = 0
            buffer.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                var start = 0
                while start < raw.count {
                    guard let hit = memchr(base + start, 0x0A, raw.count - start) else { break }
                    let end = UnsafePointer<UInt8>(hit.assumingMemoryBound(to: UInt8.self)) - base
                    let length = dropped + end - start
                    if checkpoint.skippingLine {
                        checkpoint.skippingLine = false
                    } else if length > limits.maxLineBytes {
                        checkpoint.skippedLines += 1
                    } else if length > 0 {
                        // No-copy view; handlers decode and discard it within this call.
                        let line = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base + start), count: length, deallocator: .none)
                        handle(line, &checkpoint.state)
                        lines += 1
                    }
                    dropped = 0
                    start = end + 1
                    consumed = bufferStart + start
                }
                lineStart = start
            }
            let rest = buffer.count - lineStart
            if checkpoint.skippingLine || dropped + rest > limits.maxLineBytes {
                dropped += rest
                buffer.removeAll(keepingCapacity: true)
            } else if lineStart > 0 {
                buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + lineStart))
            }
            if part.count < count { break }
        }
        guard readTotal > 0 else {
            checkpoint = before
            checkpoint.readError = "Read failed"
            return ReadOutcome(bytesRead: 0, linesHandled: 0, reset: didReset)
        }
        checkpoint.readError = nil
        checkpoint.lastReadAt = now.timeIntervalSince1970
        let tail = readTotal - consumed
        // A trailing fragment already longer than a line may be is skipped, not deferred forever.
        if tail > limits.maxLineBytes || (consumed == 0 && tail == limits.maxBytesPerPass) {
            if !checkpoint.skippingLine { checkpoint.skippedLines += 1 }
            checkpoint.skippingLine = true
            consumed = readTotal
        }
        checkpoint.offset += UInt64(consumed)
        if checkpoint.offset + UInt64(readTotal - consumed) == stat.size {
            checkpoint.deferredBytes = UInt64(readTotal - consumed)
        }
        return ReadOutcome(bytesRead: readTotal, linesHandled: lines, reset: didReset)
    }
}

/// Fast field helpers for raw lines (no full decode).
enum LineScan {
    static func contains(_ line: Data, _ marker: StaticString, within limit: Int? = nil) -> Bool {
        line.withUnsafeBytes { raw in
            let count = min(raw.count, limit ?? raw.count)
            return memmem(raw.baseAddress, count, marker.utf8Start, marker.utf8CodeUnitCount) != nil
        }
    }

    /// Codex lines start with `{"timestamp":"<iso>"`; read it without decoding the line.
    static func leadingTimestamp(_ line: Data) -> Date? {
        let prefix: StaticString = "{\"timestamp\":\""
        return line.withUnsafeBytes { raw -> Date? in
            let n = prefix.utf8CodeUnitCount
            guard raw.count > n + 20, memcmp(raw.baseAddress, prefix.utf8Start, n) == 0 else { return nil }
            return Timestamps.parseUTC(UnsafeRawBufferPointer(rebasing: raw[n..<min(raw.count, n + 40)]))
        }
    }
}

public enum Timestamps {
    private static let lock = NSLock()
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Lock-free parser for `YYYY-MM-DDTHH:MM:SS[.fraction]Z`, the form both CLIs write.
    static func parseUTC(_ b: UnsafeRawBufferPointer) -> Date? {
        guard b.count >= 20 else { return nil }
        func num(_ from: Int, _ len: Int) -> Int? {
            var v = 0
            for i in from..<(from + len) {
                let c = Int(b[i]) - 48
                guard c >= 0 && c <= 9 else { return nil }
                v = v * 10 + c
            }
            return v
        }
        guard b[4] == 0x2D, b[7] == 0x2D, b[10] == 0x54, b[13] == 0x3A, b[16] == 0x3A,
              let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2), let h = num(11, 2), let mi = num(14, 2), let s = num(17, 2) else { return nil }
        var i = 19
        var fraction = 0.0
        if b[i] == 0x2E {
            var scale = 0.1
            i += 1
            while i < b.count, b[i] >= 48, b[i] <= 57 { fraction += Double(b[i] - 48) * scale; scale /= 10; i += 1 }
        }
        guard i < b.count, b[i] == 0x5A else { return nil }
        let seconds = daysSinceEpoch(year: y, month: mo) * 86_400 + (d - 1) * 86_400 + h * 3_600 + mi * 60 + s
        return Date(timeIntervalSince1970: Double(seconds) + fraction)
    }

    /// Days from 1970-01-01 to the first day of `month` (1-based) of `year`, proleptic Gregorian, UTC.
    /// Out-of-range months carry into the year the way `timegm` normalizes them. Pure arithmetic:
    /// `timegm` consults the time zone on every call, which is slow when parsing many timestamps.
    static func daysSinceEpoch(year: Int, month: Int) -> Int {
        let carry = (month - 1) >= 0 ? (month - 1) / 12 : -((12 - month) / 12)
        let m = month - 12 * carry
        let y = (m <= 2 ? year + carry - 1 : year + carry)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    public static func parse(_ value: String?) -> Date? {
        guard var string = value, !string.isEmpty else { return nil }
        let fast = string.utf8.withContiguousStorageIfAvailable { parseUTC(UnsafeRawBufferPointer($0)) }
            ?? Array(string.utf8).withUnsafeBytes { parseUTC($0) }
        if let fast { return fast }
        // Codex writes microseconds; ISO8601DateFormatter accepts at most milliseconds.
        if let dot = string.firstIndex(of: "."),
           let zone = string[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }),
           string.distance(from: dot, to: zone) > 4 {
            string = String(string[..<string.index(dot, offsetBy: 4)]) + String(string[zone...])
        }
        lock.lock()
        defer { lock.unlock() }
        return fractional.date(from: string) ?? plain.date(from: string)
    }
}
