import Foundation
import Testing
@testable import LighthouseCore

/// M7 C3/C6: `JSONLTail.advance` reads a pass in slices. Every pass must hand the same lines, skips,
/// offsets and deferred bytes as one read of the whole pass budget (the pre-M7 reader, kept below
/// as the oracle), for any slice size, line length mix, and append pattern.
@Suite struct IngestionSliceTests {
    struct Lines: Codable, Sendable, Equatable { var seen: [String] = [] }

    /// In-memory file: one path, fixed identity, growing contents. Optionally fails one read.
    final class MemoryFile: SourceAccess, @unchecked Sendable {
        var bytes = Data()
        var failReadAt: Int?
        var reads = 0
        func stat(_ path: String) -> FileStat? { FileStat(device: 1, inode: 7, size: UInt64(bytes.count), mtime: 1, isDirectory: false) }
        func list(_ directory: String) -> [String] { [] }
        func isReadable(_ path: String) -> Bool { true }
        func read(_ path: String, offset: UInt64, count: Int) -> Data? {
            defer { reads += 1 }
            if reads == failReadAt { return nil }
            let start = min(Int(offset), bytes.count), end = min(start + count, bytes.count)
            return bytes.subdata(in: start..<end)
        }
        func scan(_ root: String, ext: String, skipping: Set<String>) -> (files: [ScannedFile], symlinks: Int) { ([], 0) }
    }

    /// The pre-M7 reader: one read of up to `maxBytesPerPass` bytes, then the same line rules.
    static func oracle(_ checkpoint: inout FileCheckpoint<Lines>, stat: FileStat, access: SourceAccess, limits: IngestLimits) {
        checkpoint.size = stat.size
        checkpoint.mtime = stat.mtime
        checkpoint.deferredBytes = 0
        guard stat.size > checkpoint.offset else { checkpoint.readError = nil; return }
        let want = Int(min(UInt64(limits.maxBytesPerPass), stat.size - checkpoint.offset))
        guard let chunk = access.read(checkpoint.path, offset: checkpoint.offset, count: want), !chunk.isEmpty else {
            checkpoint.readError = "Read failed"
            return
        }
        checkpoint.readError = nil
        var consumed = 0
        let raw = [UInt8](chunk)
        var start = 0
        while start < raw.count {
            guard let newline = raw[start...].firstIndex(of: 0x0A) else { break }
            let length = newline - start
            if checkpoint.skippingLine {
                checkpoint.skippingLine = false
            } else if length > limits.maxLineBytes {
                checkpoint.skippedLines += 1
            } else if length > 0 {
                checkpoint.state.seen.append(String(decoding: raw[start..<newline], as: UTF8.self))
            }
            start = newline + 1
            consumed = start
        }
        let tail = raw.count - consumed
        if tail > limits.maxLineBytes || (consumed == 0 && tail == limits.maxBytesPerPass) {
            if !checkpoint.skippingLine { checkpoint.skippedLines += 1 }
            checkpoint.skippingLine = true
            consumed = raw.count
        }
        checkpoint.offset += UInt64(consumed)
        if checkpoint.offset + UInt64(raw.count - consumed) == stat.size { checkpoint.deferredBytes = UInt64(raw.count - consumed) }
    }

    static func fresh() -> FileCheckpoint<Lines> {
        FileCheckpoint(path: "/m", device: 1, inode: 7, size: 0, offset: 0, mtime: 0, skippedLines: 0, skippingLine: false, state: Lines())
    }

    static func same(_ a: FileCheckpoint<Lines>, _ b: FileCheckpoint<Lines>) -> Bool {
        a.offset == b.offset && a.size == b.size && a.skippedLines == b.skippedLines && a.skippingLine == b.skippingLine
            && a.deferredBytes == b.deferredBytes && a.state == b.state && a.readError == b.readError
    }

    @Test func slicedPassesMatchOneReadPerPass() {
        var generator = SystemRandomNumberGenerator()
        for round in 0..<400 {
            let maxLine = Int.random(in: 1...40, using: &generator)
            let maxPass = Int.random(in: 1...120, using: &generator)
            let slice = Int.random(in: 1...50, using: &generator)
            let limits = IngestLimits(maxBytesPerPass: maxPass, maxLineBytes: maxLine)
            let file = MemoryFile()
            var sliced = Self.fresh(), expected = Self.fresh()
            for _ in 0..<12 {
                // Append a few lines of random length (0…3× the line limit), sometimes without the newline.
                for _ in 0..<Int.random(in: 0...4, using: &generator) {
                    let length = Int.random(in: 0...(3 * maxLine), using: &generator)
                    file.bytes.append(contentsOf: (0..<length).map { _ in UInt8.random(in: 97...122, using: &generator) })
                    if Bool.random(using: &generator) || length == 0 { file.bytes.append(0x0A) }
                }
                for _ in 0..<Int.random(in: 1...3, using: &generator) {
                    let stat = file.stat("/m")!
                    let outcome = JSONLTail.advance(&sliced, stat: stat, access: file, limits: limits, now: Date(), sliceBytes: slice,
                                                    reset: { $0 = Lines() }, handle: { line, s in s.seen.append(String(decoding: line, as: UTF8.self)) })
                    Self.oracle(&expected, stat: stat, access: file, limits: limits)
                    #expect(Self.same(sliced, expected), "round \(round) maxLine \(maxLine) maxPass \(maxPass) slice \(slice)")
                    #expect(outcome.bytesRead <= maxPass)
                    if !Self.same(sliced, expected) { return }
                }
            }
        }
    }

    /// A read that fails part-way leaves the checkpoint as it was, with the read error (as a failed single read did).
    @Test func failedSliceLeavesCheckpointUnchanged() {
        let file = MemoryFile()
        file.bytes = Data("one\ntwo\nthree\nfour\n".utf8)
        var c = Self.fresh()
        file.failReadAt = 1
        let limits = IngestLimits(maxBytesPerPass: 64, maxLineBytes: 16)
        let outcome = JSONLTail.advance(&c, stat: file.stat("/m")!, access: file, limits: limits, now: Date(), sliceBytes: 5,
                                        reset: { $0 = Lines() }, handle: { line, s in s.seen.append(String(decoding: line, as: UTF8.self)) })
        #expect(outcome.bytesRead == 0)
        #expect(c.offset == 0 && c.state.seen.isEmpty && c.readError == "Read failed" && c.lastReadAt == nil)
        file.failReadAt = nil
        _ = JSONLTail.advance(&c, stat: file.stat("/m")!, access: file, limits: limits, now: Date(), sliceBytes: 5,
                              reset: { $0 = Lines() }, handle: { line, s in s.seen.append(String(decoding: line, as: UTF8.self)) })
        #expect(c.state.seen == ["one", "two", "three", "four"] && c.readError == nil)
    }

    /// Memory stays bounded by one slice plus one line: a 4 MB pass of short lines is read in slices.
    @Test func defaultPassReadsInSlices() {
        let file = MemoryFile()
        let line = Data(repeating: 0x61, count: 1023) + Data([0x0A])
        for _ in 0..<(4 << 10) { file.bytes.append(line) }
        var c = Self.fresh()
        let outcome = JSONLTail.advance(&c, stat: file.stat("/m")!, access: file, limits: .standard, now: Date(),
                                        reset: { $0 = Lines() }, handle: { _, s in s.seen.append("") })
        #expect(outcome.bytesRead == 4 << 20)
        #expect(c.state.seen.count == (4 << 20) / 1024)
        #expect(file.reads == (4 << 20) / JSONLTail.sliceBytes)
    }
}
