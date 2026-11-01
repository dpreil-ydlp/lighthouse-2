import Foundation

public struct PassResult: Sendable {
    public var threads: [SessionThread]
    public var status: CollectorStatus
    public var bytesRead: Int
    /// True while any file in the index window still has unread bytes.
    public var hasMore: Bool

    public init(threads: [SessionThread], status: CollectorStatus, bytesRead: Int, hasMore: Bool) {
        self.threads = threads
        self.status = status
        self.bytesRead = bytesRead
        self.hasMore = hasMore
    }
}

/// A read-only source of threads. Claude Code and Codex conform in M1; the T3 reader plugs in at M3.
public protocol SessionCollector: Actor {
    nonisolated var kind: SourceKind { get }
    /// Folders whose changes should trigger a pass (FSEvents). Empty when the source is polled.
    nonisolated var watchedPaths: [String] { get }
    /// One bounded pass (SPEC §3.1): at most `maxBytesPerPass` per file. Persists checkpoints.
    func pass(now: Date, scope: PassScope) async -> PassResult
    /// Threads assembled from checkpoints loaded from the store, with no source I/O. Lets the
    /// panel show the last known shelf right after launch, before the first pass.
    func restoredThreads(now: Date) -> [SessionThread]
}

/// Which files a pass looks at.
public enum PassScope: Sendable, Hashable {
    /// Walk the source folders (startup and the 60 s rescan).
    case full
    /// Only known files that still have unread bytes (back-to-back catch-up during indexing).
    case pending
    /// Files FSEvents reported, plus pending ones. Avoids a folder walk per event.
    case paths(Set<String>)
}

extension SessionCollector {
    public func pass(now: Date) async -> PassResult { await pass(now: now, scope: .full) }
}

/// Last successful read per file, kept in memory between passes so unchanged files need no write.
struct ReadTimes {
    private var times: [String: Double] = [:]

    mutating func record<S>(plan: PassPlan<S>, done: [FileWork<S>], now: Date) {
        for path in plan.observed { times[path] = now.timeIntervalSince1970 }
        for work in done where !work.checkpoint.unreadable { times[work.path] = now.timeIntervalSince1970 }
    }

    /// SPEC §5.3 `sourceReadAt`: the last successful read, never the time of a failed attempt.
    func sourceReadAt<S>(_ item: FileCheckpoint<S>) -> Date {
        let best = max(times[item.path] ?? 0, item.lastReadAt ?? 0)
        return Date(timeIntervalSince1970: best)
    }

    /// Collector error line: the root problem, else a count of unreadable files.
    static func error<S>(root: RootCheck, rootPath: String, items: [FileCheckpoint<S>]) -> String? {
        if let message = root.message(rootPath) { return message }
        let failed = items.filter(\.unreadable)
        guard let first = failed.first else { return nil }
        return "\(failed.count) file\(failed.count == 1 ? "" : "s") unreadable (\(first.readError ?? "read failed"): \(first.path))"
    }
}

/// Cached result of the last folder walk.
struct Discovery {
    var present = Set<String>()
    var inWindow = 0
    var notIndexed = 0
    /// File sizes at discovery. Catch-up passes stop at these sizes; later appends are live work
    /// handled by FSEvents passes, so indexing finishes even while agents keep writing.
    var targets: [String: UInt64] = [:]
    /// Files with unread bytes from discovery; shrinks as passes catch up.
    var backlog = Set<String>()

    mutating func settle<S>(_ checkpoint: FileCheckpoint<S>) {
        if !checkpoint.hasBacklog(target: targets[checkpoint.path]) { backlog.remove(checkpoint.path) }
    }
}

extension FileCheckpoint {
    /// True while bytes that existed at discovery are still unread.
    func hasBacklog(target: UInt64?) -> Bool {
        guard !unreadable else { return false }
        return offset + deferredBytes < min(target ?? size, size)
    }
}

/// A checkpoint as persisted: file identity and position columns plus the encoded state struct.
public struct StoredCheckpoint: Sendable, Hashable {
    public var path: String
    public var device: UInt64
    public var inode: UInt64
    public var size: UInt64
    public var offset: UInt64
    public var mtime: Double
    public var skippedLines: Int
    public var skippingLine: Bool
    /// JSON of the collector's state struct (`ClaudeFileState`, `CodexFileState`, `CodexIndexState`).
    public var state: Data
    public var lastReadAt: Double?
    public var readError: String?

    public init(path: String, device: UInt64, inode: UInt64, size: UInt64, offset: UInt64, mtime: Double,
                skippedLines: Int, skippingLine: Bool, state: Data, lastReadAt: Double? = nil, readError: String? = nil) {
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

/// Persists collector checkpoints. `Store` implements it; tests may use an in-memory version.
public protocol CheckpointStore: Sendable {
    func loadCheckpoints(source: SourceKind) -> [String: StoredCheckpoint]
    func saveCheckpoints(source: SourceKind, changed: [StoredCheckpoint], removed: [String])
}

extension FileCheckpoint {
    init?(stored: StoredCheckpoint) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let state = try? decoder.decode(State.self, from: stored.state) else { return nil }
        self.init(path: stored.path, device: stored.device, inode: stored.inode, size: stored.size, offset: stored.offset,
                  mtime: stored.mtime, skippedLines: stored.skippedLines, skippingLine: stored.skippingLine, state: state,
                  lastReadAt: stored.lastReadAt, readError: stored.readError)
    }

    var stored: StoredCheckpoint? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(state) else { return nil }
        return StoredCheckpoint(path: path, device: device, inode: inode, size: size, offset: offset, mtime: mtime,
                                skippedLines: skippedLines, skippingLine: skippingLine, state: data,
                                lastReadAt: lastReadAt, readError: readError)
    }
}

/// Checkpoint bookkeeping shared by the JSONL collectors.
struct CheckpointSet<State: Codable & Sendable> {
    var items: [String: FileCheckpoint<State>] = [:]
    private var dirty = Set<String>()
    private var removed = Set<String>()

    init(source: SourceKind, store: CheckpointStore?) {
        guard let store else { return }
        for (path, stored) in store.loadCheckpoints(source: source) {
            if let checkpoint = FileCheckpoint<State>(stored: stored) { items[path] = checkpoint }
        }
    }

    mutating func update(_ checkpoint: FileCheckpoint<State>) {
        items[checkpoint.path] = checkpoint
        dirty.insert(checkpoint.path)
        removed.remove(checkpoint.path)
    }

    mutating func drop(missingFrom present: Set<String>) {
        for path in items.keys where !present.contains(path) {
            items[path] = nil
            removed.insert(path)
            dirty.remove(path)
        }
    }

    mutating func flush(source: SourceKind, store: CheckpointStore?) {
        defer { dirty.removeAll(); removed.removeAll() }
        guard let store, !(dirty.isEmpty && removed.isEmpty) else { return }
        let changed = dirty.compactMap { items[$0]?.stored }
        store.saveCheckpoints(source: source, changed: changed, removed: Array(removed))
    }
}

/// One file's work for a pass, computed in parallel.
struct FileWork<State: Codable & Sendable>: Sendable {
    var path: String
    var stat: FileStat
    var checkpoint: FileCheckpoint<State>
    var bytesRead: Int = 0
}

enum ParallelMap {
    /// Workers for file parsing: half the active cores (at least 2). The rest stay free for the
    /// main thread and WindowServer, so the panel opens within budget while indexing (SPEC §3.2).
    static let workers = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)

    static func run<T: Sendable, U: Sendable>(_ items: [T], _ transform: @Sendable (T) -> U) -> [U] {
        guard items.count > 1 else { return items.map(transform) }
        let box = ResultBox<U>(count: items.count)
        let next = Counter()
        DispatchQueue.concurrentPerform(iterations: min(workers, items.count)) { _ in
            while let index = next.take(limit: items.count) {
                autoreleasepool { box.set(index, transform(items[index])) }
            }
        }
        return box.values()
    }

    private final class Counter: @unchecked Sendable {
        private var value = 0
        private let lock = NSLock()
        func take(limit: Int) -> Int? {
            lock.lock(); defer { lock.unlock() }
            guard value < limit else { return nil }
            defer { value += 1 }
            return value
        }
    }

    private final class ResultBox<U>: @unchecked Sendable {
        private var storage: [U?]
        private let lock = NSLock()
        init(count: Int) { storage = Array(repeating: nil, count: count) }
        func set(_ index: Int, _ value: U) { lock.lock(); storage[index] = value; lock.unlock() }
        func values() -> [U] { storage.map { $0! } }
    }
}

/// Plans a pass: which files are in the window, which changed, and newest-first order (SPEC §3.1).
struct PassPlan<State: Codable & Sendable> {
    var work: [FileWork<State>] = []
    var inWindow = 0
    var notIndexed = 0
    var present = Set<String>()

    var targets: [String: UInt64] = [:]
    var backlog = Set<String>()
    /// Unchanged files confirmed readable this pass; their source-read time advances without a read.
    var observed = Set<String>()

    var discovery: Discovery { Discovery(present: present, inWindow: inWindow, notIndexed: notIndexed, targets: targets, backlog: backlog) }

    /// Catch-up plan: known files that still have unread bytes, plus `touched` files (new or changed).
    init(pendingFrom checkpoints: [String: FileCheckpoint<State>], touched: Set<String> = [], discovery: Discovery,
         access: SourceAccess, initial: (String) -> State) {
        present = discovery.present
        inWindow = discovery.inWindow
        notIndexed = discovery.notIndexed
        targets = discovery.targets
        backlog = discovery.backlog
        var paths = backlog.intersection(present)
        // FSEvents paths arrive as bridged strings; store native ones (see `ReadOnlyFileSystem.join`).
        paths.formUnion(touched.map { path in var native = path; native.makeContiguousUTF8(); return native })
        for path in paths {
            guard let stat = access.stat(path), !stat.isDirectory, !stat.isSymlink else { continue }
            if !present.contains(path) {
                present.insert(path)
                inWindow += 1
                targets[path] = stat.size
            }
            let checkpoint = checkpoints[path] ?? FileCheckpoint(
                path: path, device: stat.device, inode: stat.inode, size: 0, offset: 0, mtime: 0,
                skippedLines: 0, skippingLine: false, state: initial(path))
            work.append(FileWork(path: path, stat: stat, checkpoint: checkpoint))
            backlog.insert(path)
        }
    }

    init(scanned: [ScannedFile], symlinks: Int = 0, checkpoints: [String: FileCheckpoint<State>], limits: IngestLimits,
         now: Date, initial: (String) -> State) {
        notIndexed = symlinks
        var candidates: [(String, FileStat)] = []
        var readable = Set<String>()
        for file in scanned {
            let path = file.path, stat = file.stat
            if file.readable { readable.insert(path) }
            present.insert(path)
            let known = checkpoints[path]
            let inside = now.timeIntervalSince1970 - stat.mtime <= limits.indexWindow
            guard known != nil || inside else { notIndexed += 1; continue }
            inWindow += 1
            targets[path] = stat.size
            candidates.append((path, stat))
        }
        candidates.sort { $0.1.mtime > $1.1.mtime }
        for (path, stat) in candidates {
            let checkpoint = checkpoints[path] ?? FileCheckpoint(
                path: path, device: stat.device, inode: stat.inode, size: 0, offset: 0, mtime: 0,
                skippedLines: 0, skippingLine: false, state: initial(path))
            let unchanged = checkpoint.inode == stat.inode && checkpoint.device == stat.device
                && checkpoint.size == stat.size && checkpoint.mtime == stat.mtime && checkpoint.isCaughtUp && !checkpoint.unreadable
            // A permission change does not change size or mtime; confirm the file still opens.
            if unchanged && readable.contains(path) {
                observed.insert(path)
            } else {
                work.append(FileWork(path: path, stat: stat, checkpoint: checkpoint))
                backlog.insert(path)
            }
        }
    }
}
