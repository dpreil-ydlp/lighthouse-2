import Foundation
import SQLite3

/// Metadata read from T3 Code's state database in one bounded read transaction (SPEC §4).
/// Every field is an id, path, title-field value, timestamp, provider name, state or request kind.
/// Message, prompt, result and request text columns are never selected (V-PRIV).
public struct T3State: Sendable, Hashable {
    public struct Project: Sendable, Hashable {
        public var id: String
        public var title: String
        public var root: String
    }

    public struct Thread: Sendable, Hashable {
        public var id: String
        public var projectId: String
        public var title: String
        public var createdAt: Date?
        public var archived: Bool
        public var worktreePath: String?
        /// `lineage.parentThreadId` when `lineage.relationshipToParent` is `subagent`.
        public var lineageParent: String?
    }

    /// Provider-thread mapping: T3 thread → native session id (`nativeThreadRef.nativeId`).
    public struct ProviderThread: Sendable, Hashable {
        public var threadId: String
        public var provider: Provider
        public var nativeId: String
    }

    /// Newest run of a thread, plus the newest completion of any of its runs.
    public struct Run: Sendable, Hashable {
        public var status: String
        public var requestedAt: Date?
        public var completedAt: Date?
        public var lastCompletedAt: Date?
    }

    /// A pending runtime request. Kind and status only; its payload is never read.
    public struct Request: Sendable, Hashable {
        public var id: String
        public var threadId: String
        public var kind: String
        public var createdAt: Date?
    }

    /// A delegated-task / subagent row: parent, child thread, state and times only.
    public struct SubagentRow: Sendable, Hashable {
        public var id: String
        public var parentThreadId: String
        public var childThreadId: String
        public var provider: String
        public var status: String
        public var startedAt: Date?
        public var completedAt: Date?
        public var updatedAt: Date?
    }

    public var environmentId: String?
    public var projects: [Project] = []
    public var threads: [Thread] = []
    public var providerThreads: [ProviderThread] = []
    public var runs: [String: Run] = [:]
    public var pendingRequests: [Request] = []
    public var subagents: [SubagentRow] = []
    /// Start of the oldest tool call (`command_execution`, `dynamic_tool`) in flight in each
    /// thread's newest run (M9 F1). Empty when T3 has no `turn_items` table.
    public var busySince: [String: Date] = [:]

    public init(environmentId: String? = nil) { self.environmentId = environmentId }
}

public enum T3ReadError: Error, Equatable, Sendable, CustomStringConvertible {
    case notFound
    case notADatabase
    /// WAL mode with a missing, non-regular or malformed `-wal`/`-shm` sidecar, or a sidecar
    /// next to a database that is not in WAL mode.
    case inconsistentSidecars(String)
    case schemaUnrecognized(String)
    case deadline
    case sqlite(String)

    public var description: String {
        switch self {
        case .notFound: "T3 unavailable: database not found"
        case .notADatabase: "T3 unavailable: not a SQLite database"
        case .inconsistentSidecars(let detail): "T3 unavailable: WAL/SHM pair inconsistent (\(detail)); pass skipped"
        case .schemaUnrecognized(let detail): "T3 unavailable: schema not recognized (\(detail)); pass skipped"
        case .deadline: "T3 unavailable: read deadline hit; pass skipped"
        case .sqlite(let detail): "T3 unavailable: \(detail)"
        }
    }
}

/// Reads `~/.t3/userdata/statev2.sqlite` in place (SPEC §4, V-T3DB). Port of the safety properties of
/// v1 `collector/t3_read.py` and the SQL extraction of v1 `collector/collector.py:93–187`.
///
/// - Preflight through `SourceAccess` (no symlink in any path component): the file must be a SQLite
///   database; in WAL mode both `-wal` and `-shm` must already exist as regular files with valid
///   headers, so SQLite never has to create a sidecar. Otherwise the pass is skipped (fail closed).
/// - Open with `mode=ro`, `readonly_shm=1` (the shared-memory index is mapped read-only too),
///   `SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW`, then `PRAGMA query_only=ON`.
/// - One `BEGIN … COMMIT` read transaction; a progress handler aborts any statement once the deadline
///   (15 s) passes, and the deadline is checked between statements.
/// - Unknown schema (a table or column this reader selects is missing) skips the pass.
/// There is no copy, cache, snapshot or fallback read path: on any failure the reader returns an error.
public struct T3Reader: Sendable {
    public static let deadline: TimeInterval = 15

    public let databasePath: String
    public let environmentIdPath: String
    public let access: SourceAccess
    public let deadline: TimeInterval
    /// Monotonic seconds. Injected by tests to hit the deadline deterministically.
    public let clock: @Sendable () -> TimeInterval
    /// Test hook: runs while the read transaction is open (to inspect open file modes).
    var whileOpen: (@Sendable () -> Void)?

    public init(t3Home: String = NSHomeDirectory() + "/.t3", access: SourceAccess = ReadOnlyFileSystem(),
                deadline: TimeInterval = T3Reader.deadline,
                clock: @escaping @Sendable () -> TimeInterval = { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }) {
        let userdata = (t3Home as NSString).appendingPathComponent("userdata")
        self.databasePath = (userdata as NSString).appendingPathComponent("statev2.sqlite")
        self.environmentIdPath = (userdata as NSString).appendingPathComponent("environment-id")
        self.access = access
        self.deadline = deadline
        self.clock = clock
    }

    /// Tables and the columns this reader selects. A database missing any of them is unrecognized.
    static let requiredColumns: [String: [String]] = [
        "projection_projects": ["project_id", "title", "workspace_root", "deleted_at"],
        "orchestration_v2_projection_threads": ["thread_id", "project_id", "title", "created_at", "archived_at", "deleted_at", "payload_json"],
        "orchestration_v2_projection_provider_threads": ["thread_id", "provider", "payload_json"],
        "orchestration_v2_projection_runs": ["thread_id", "ordinal", "status", "requested_at", "completed_at"],
        "orchestration_v2_projection_runtime_requests": ["runtime_request_id", "thread_id", "kind", "status", "created_at"],
        "orchestration_v2_projection_subagents": ["subagent_id", "thread_id", "child_thread_id", "provider", "status",
                                                  "started_at", "completed_at", "updated_at"],
    ]

    /// Optional table (M9 F1): read when it has these columns, otherwise skipped without failing the pass.
    static let turnItemsTable = "orchestration_v2_projection_turn_items"
    static let turnItemsColumns = ["thread_id", "run_id", "type", "status", "updated_at", "payload_json"]

    /// Every statement the reader runs, in order. Exposed so tests can assert no text column is selected.
    /// The last one reads in-flight tool calls; its WHERE matches T3's partial index
    /// `…_turn_items_recovery_idx` exactly, so it scans only in-flight items, never the whole table.
    static let queries: [String] = [
        "SELECT project_id, title, workspace_root FROM projection_projects WHERE deleted_at IS NULL",
        """
        SELECT thread_id, project_id, title, created_at, archived_at,
          CASE WHEN json_valid(payload_json) THEN json_extract(payload_json, '$.worktreePath') END,
          CASE WHEN json_valid(payload_json) AND json_extract(payload_json, '$.lineage.relationshipToParent') = 'subagent'
            THEN json_extract(payload_json, '$.lineage.parentThreadId') END
        FROM orchestration_v2_projection_threads WHERE deleted_at IS NULL
        """,
        """
        SELECT thread_id, provider,
          CASE WHEN json_valid(payload_json) THEN json_extract(payload_json, '$.nativeThreadRef.nativeId') END
        FROM orchestration_v2_projection_provider_threads WHERE thread_id IS NOT NULL
        """,
        """
        SELECT latest.thread_id, latest.status, latest.requested_at, latest.completed_at,
          (SELECT MAX(done.completed_at) FROM orchestration_v2_projection_runs done WHERE done.thread_id = latest.thread_id)
        FROM orchestration_v2_projection_runs latest
        WHERE latest.ordinal = (SELECT MAX(o.ordinal) FROM orchestration_v2_projection_runs o WHERE o.thread_id = latest.thread_id)
        """,
        "SELECT runtime_request_id, thread_id, kind, created_at FROM orchestration_v2_projection_runtime_requests WHERE status = 'pending'",
        """
        SELECT subagent_id, thread_id, child_thread_id, provider, status, started_at, completed_at, updated_at
        FROM orchestration_v2_projection_subagents WHERE child_thread_id IS NOT NULL
        """,
        """
        SELECT thread_id, type, CASE WHEN json_valid(payload_json) THEN json_extract(payload_json, '$.startedAt') END, updated_at
        FROM orchestration_v2_projection_turn_items
        WHERE type IN ('command_execution', 'dynamic_tool', 'subagent') AND status IN ('pending', 'running', 'waiting')
          AND run_id = (SELECT newest.run_id FROM orchestration_v2_projection_runs newest
                        WHERE newest.thread_id = orchestration_v2_projection_turn_items.thread_id ORDER BY newest.ordinal DESC LIMIT 1)
        """,
    ]

    public func read() -> Result<T3State, T3ReadError> {
        let start = clock()
        let expired: @Sendable () -> Bool = { [clock, deadline] in clock() - start >= deadline }
        if let failure = preflight() { return .failure(failure) }
        var state = T3State(environmentId: readEnvironmentId())

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOFOLLOW | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(Self.uri(databasePath), &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close_v2(db)
            return .failure(.sqlite(message))
        }
        defer { sqlite3_close_v2(db) }
        let box = Unmanaged.passRetained(DeadlineBox(expired))
        defer { box.release() }
        sqlite3_progress_handler(db, 1000, { context in
            guard let context else { return 1 }
            return Unmanaged<DeadlineBox>.fromOpaque(context).takeUnretainedValue().expired() ? 1 : 0
        }, box.toOpaque())
        sqlite3_busy_timeout(db, 1000)

        let connection = Connection(db: db, expired: expired)
        do {
            try connection.exec("PRAGMA query_only = ON")
            try connection.exec("BEGIN")
            // Ends the read transaction on every path, including after the deadline (no expiry check).
            defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
            try checkSchema(connection)
            whileOpen?()
            try connection.rows(Self.queries[0]) { r in
                guard let id = r.text(0), let root = r.text(2), !root.isEmpty else { return }
                state.projects.append(.init(id: id, title: r.text(1) ?? "", root: root))
            }
            try connection.rows(Self.queries[1]) { r in
                guard let id = r.text(0), let project = r.text(1) else { return }
                state.threads.append(.init(id: id, projectId: project, title: r.text(2) ?? "", createdAt: Timestamps.parse(r.text(3)),
                                           archived: r.text(4) != nil, worktreePath: r.text(5).flatMap { $0.isEmpty ? nil : $0 },
                                           lineageParent: r.text(6)))
            }
            try connection.rows(Self.queries[2]) { r in
                guard let thread = r.text(0), let native = r.text(2), !native.isEmpty,
                      let provider = Self.provider(r.text(1)) else { return }
                state.providerThreads.append(.init(threadId: thread, provider: provider, nativeId: native))
            }
            try connection.rows(Self.queries[3]) { r in
                guard let thread = r.text(0), let status = r.text(1) else { return }
                state.runs[thread] = .init(status: status, requestedAt: Timestamps.parse(r.text(2)),
                                           completedAt: Timestamps.parse(r.text(3)), lastCompletedAt: Timestamps.parse(r.text(4)))
            }
            try connection.rows(Self.queries[4]) { r in
                guard let id = r.text(0), let thread = r.text(1), let kind = r.text(2) else { return }
                state.pendingRequests.append(.init(id: id, threadId: thread, kind: kind, createdAt: Timestamps.parse(r.text(3))))
            }
            try connection.rows(Self.queries[5]) { r in
                guard let id = r.text(0), let parent = r.text(1), let child = r.text(2), let status = r.text(4) else { return }
                state.subagents.append(.init(id: id, parentThreadId: parent, childThreadId: child, provider: r.text(3) ?? "",
                                             status: status, startedAt: Timestamps.parse(r.text(5)), completedAt: Timestamps.parse(r.text(6)),
                                             updatedAt: Timestamps.parse(r.text(7))))
            }
            if try hasTurnItems(connection) {
                try connection.rows(Self.queries[6]) { r in
                    // Delegated subagents are covered by their own rows; only tool calls make a thread busy.
                    guard let thread = r.text(0), r.text(1) != "subagent",
                          let started = Timestamps.parse(r.text(2)) ?? Timestamps.parse(r.text(3)) else { return }
                    state.busySince[thread] = min(state.busySince[thread] ?? started, started)
                }
            }
            try connection.exec("COMMIT")
        } catch let error as T3ReadError {
            return .failure(error)
        } catch {
            return .failure(.sqlite("\(error)"))
        }
        return .success(state)
    }

    /// T3 driver names → model provider. Other drivers carry no usage attribution and are not mapped.
    static func provider(_ driver: String?) -> Provider? {
        switch driver {
        case "codex": .codex
        case "claudeAgent": .claude
        default: nil
        }
    }

    /// Identity, size and mtime of the database and its WAL. Equal values mean no commit and no
    /// checkpoint happened since the last read, so the last state still holds.
    public func fileStamps() -> [FileStat?] {
        [access.stat(databasePath), access.stat(databasePath + "-wal")]
    }

    // MARK: Preflight (fail closed)

    static let sqliteMagic = Data("SQLite format 3\u{0}".utf8)

    func preflight() -> T3ReadError? {
        guard let stat = access.stat(databasePath), !stat.isSymlink, !stat.isDirectory else { return .notFound }
        guard let header = access.read(databasePath, offset: 0, count: 100), header.count == 100,
              header.prefix(16) == Self.sqliteMagic else { return .notADatabase }
        // Bytes 18 and 19 (file format write/read version) are 2 in WAL mode.
        let walMode = header[header.startIndex + 18] == 2 && header[header.startIndex + 19] == 2
        let wal = access.stat(databasePath + "-wal")
        let shm = access.stat(databasePath + "-shm")
        guard walMode else {
            if wal != nil || shm != nil { return .inconsistentSidecars("sidecar present but database is not in WAL mode") }
            if access.stat(databasePath + "-journal") != nil { return .inconsistentSidecars("rollback journal present") }
            return nil
        }
        guard let wal, let shm else { return .inconsistentSidecars(wal == nil ? "-wal missing" : "-shm missing") }
        guard !wal.isSymlink, !wal.isDirectory, !shm.isSymlink, !shm.isDirectory else { return .inconsistentSidecars("sidecar is not a regular file") }
        // The shared-memory index is mapped read-only; it must already be initialized by T3.
        guard shm.size >= 32768 else { return .inconsistentSidecars("-shm not initialized") }
        if wal.size > 0 {
            guard wal.size >= 32, let walHeader = access.read(databasePath + "-wal", offset: 0, count: 4), walHeader.count == 4,
                  walHeader == Data([0x37, 0x7f, 0x06, 0x82]) || walHeader == Data([0x37, 0x7f, 0x06, 0x83]) else {
                return .inconsistentSidecars("-wal header invalid")
            }
        }
        return nil
    }

    func checkSchema(_ connection: Connection) throws {
        for (table, required) in Self.requiredColumns.sorted(by: { $0.key < $1.key }) {
            var columns = Set<String>()
            try connection.rows("PRAGMA table_info(\(table))") { r in if let name = r.text(1) { columns.insert(name) } }
            if columns.isEmpty { throw T3ReadError.schemaUnrecognized("table \(table) missing") }
            if let missing = required.first(where: { !columns.contains($0) }) {
                throw T3ReadError.schemaUnrecognized("\(table).\(missing) missing")
            }
        }
    }

    /// Whether the optional `turn_items` table is present with every column the busy query reads.
    func hasTurnItems(_ connection: Connection) throws -> Bool {
        var columns = Set<String>()
        try connection.rows("PRAGMA table_info(\(Self.turnItemsTable))") { r in if let name = r.text(1) { columns.insert(name) } }
        return Self.turnItemsColumns.allSatisfy(columns.contains)
    }

    /// T3's own environment id for `t3code://threads/<environment-id>/<thread-id>` links.
    func readEnvironmentId() -> String? {
        guard let stat = access.stat(environmentIdPath), !stat.isSymlink, !stat.isDirectory, stat.size > 0, stat.size <= 256,
              let data = access.read(environmentIdPath, offset: 0, count: Int(stat.size)) else { return nil }
        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ":._%-"))
        guard (1...200).contains(value.count), value.unicodeScalars.allSatisfy({ allowed.contains($0) && $0.isASCII }) else { return nil }
        return value
    }

    static func uri(_ path: String) -> String {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#%"))) ?? path
        return "file:\(encoded)?mode=ro&readonly_shm=1"
    }

    // MARK: SQLite helpers

    final class DeadlineBox {
        let expired: @Sendable () -> Bool
        init(_ expired: @escaping @Sendable () -> Bool) { self.expired = expired }
    }

    struct Connection {
        let db: OpaquePointer
        let expired: @Sendable () -> Bool

        struct Row {
            let statement: OpaquePointer
            func text(_ index: Int32) -> String? {
                guard sqlite3_column_type(statement, index) != SQLITE_NULL, let c = sqlite3_column_text(statement, index) else { return nil }
                return String(cString: c)
            }
        }

        func exec(_ sql: String) throws {
            try rows(sql) { _ in }
        }

        func rows(_ sql: String, _ body: (Row) throws -> Void) throws {
            if expired() { throw T3ReadError.deadline }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                sqlite3_finalize(statement)
                throw failure()
            }
            defer { sqlite3_finalize(statement) }
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { break }
                guard code == SQLITE_ROW else { throw failure() }
                try body(Row(statement: statement))
            }
            if expired() { throw T3ReadError.deadline }
        }

        private func failure() -> T3ReadError {
            if expired() || sqlite3_errcode(db) == SQLITE_INTERRUPT { return .deadline }
            return .sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }
}
