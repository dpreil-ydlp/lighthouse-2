import Foundation
@testable import LighthouseCore

/// A scratch directory under the system temp folder, removed on deinit.
final class Scratch {
    let url: URL
    var path: String { url.path }

    init() {
        // Resolved path: `/var` is a symlink to `/private/var`, and the source boundary rejects
        // symlinked ancestors.
        let base = URL(fileURLWithPath: realpath(NSTemporaryDirectory(), nil).map { p in defer { free(p) }; return String(cString: p) }!)
        url = base.appendingPathComponent("lh2-tests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func dir(_ relative: String) -> String {
        let p = url.appendingPathComponent(relative).path
        try! FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    @discardableResult
    func write(_ relative: String, _ text: String) -> String {
        let p = url.appendingPathComponent(relative).path
        try! FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try! text.write(toFile: p, atomically: false, encoding: .utf8)
        return p
    }

    func append(_ relative: String, _ text: String) {
        let handle = FileHandle(forWritingAtPath: url.appendingPathComponent(relative).path)!
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
        handle.closeFile()
    }

    /// Copies the bundled fixture tree (test data, never live state) into this scratch folder.
    func installFixtures() {
        let source = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
        for name in ["claude", "codex"] {
            try! FileManager.default.copyItem(at: source.appendingPathComponent(name), to: url.appendingPathComponent(name))
        }
    }

    var claudeRoot: String { url.appendingPathComponent("claude").path }
    var codexHome: String { url.appendingPathComponent("codex").path }
}

enum Fixture {
    static let bodyCanary = "CANARY-BODY-7f3a91"
    static let secretCanary = "sk-ant-CANARYSECRET-0000"
    static let claudeSession = "11111111-1111-4111-8111-111111111111"
    static let claudeSecond = "22222222-2222-4222-8222-222222222222"
    static let codexParent = "019a0000-0000-7000-8000-000000000001"
    static let codexChild = "019a0000-0000-7000-8000-000000000002"
    static let codexT3 = "019a0000-0000-7000-8000-000000000003"

    static func date(_ iso: String) -> Date { Timestamps.parse(iso)! }
}

/// In-memory checkpoint store.
final class MemoryCheckpoints: CheckpointStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: [SourceKind: [String: StoredCheckpoint]] = [:]

    func loadCheckpoints(source: SourceKind) -> [String: StoredCheckpoint] {
        lock.lock(); defer { lock.unlock() }
        return data[source] ?? [:]
    }

    func saveCheckpoints(source: SourceKind, changed: [StoredCheckpoint], removed: [String]) {
        lock.lock(); defer { lock.unlock() }
        for c in changed { data[source, default: [:]][c.path] = c }
        for r in removed { data[source]?[r] = nil }
    }
}

/// Wraps the read-only file system and records every operation and path (no-copy guard).
final class RecordingAccess: SourceAccess, @unchecked Sendable {
    private let inner = ReadOnlyFileSystem()
    private let lock = NSLock()
    private(set) var operations: [(op: String, path: String)] = []
    var failReads = false
    /// Paths (prefix match) that fail to open, simulating a permission error.
    var deniedPrefixes: [String] = []

    private func record(_ op: String, _ path: String) {
        lock.lock(); operations.append((op, path)); lock.unlock()
    }

    func stat(_ path: String) -> FileStat? { record("stat", path); return inner.stat(path) }
    func isReadable(_ path: String) -> Bool {
        record("isReadable", path)
        return !failReads && !denied(path) && inner.isReadable(path)
    }
    private func denied(_ path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return deniedPrefixes.contains { path.hasPrefix($0) }
    }
    func deny(_ prefix: String) { lock.lock(); deniedPrefixes.append(prefix); lock.unlock() }
    func allowAll() { lock.lock(); deniedPrefixes.removeAll(); lock.unlock() }
    func list(_ directory: String) -> [String] { record("list", directory); return inner.list(directory) }
    func scan(_ root: String, ext: String, skipping: Set<String>) -> (files: [ScannedFile], symlinks: Int) {
        record("scan", root)
        let result = inner.scan(root, ext: ext, skipping: skipping)
        let files = result.files.map { file in
            var file = file
            if failReads || denied(file.path) { file.readable = false }
            return file
        }
        return (files, result.symlinks)
    }
    func read(_ path: String, offset: UInt64, count: Int) -> Data? {
        record("read", path)
        return failReads || denied(path) ? nil : inner.read(path, offset: offset, count: count)
    }
}

/// Snapshot of a directory tree: relative path → (size, mtime, sha-like checksum of bytes).
func treeFingerprint(_ root: String) -> [String: String] {
    var result: [String: String] = [:]
    let fm = FileManager.default
    guard let e = fm.enumerator(atPath: root) else { return [:] }
    for case let rel as String in e {
        let p = (root as NSString).appendingPathComponent(rel)
        let attrs = try? fm.attributesOfItem(atPath: p)
        let data = fm.contents(atPath: p) ?? Data()
        var hash: UInt64 = 1469598103934665603
        for b in data { hash = (hash ^ UInt64(b)) &* 1099511628211 }
        result[rel] = "\(attrs?[.size] ?? 0)|\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\(hash)"
    }
    return result
}

func bytesContain(_ path: String, _ needle: String) -> Bool {
    guard let data = FileManager.default.contents(atPath: path) else { return false }
    return data.range(of: Data(needle.utf8)) != nil
}
