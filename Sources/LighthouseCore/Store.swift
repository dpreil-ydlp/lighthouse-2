import Foundation
import SQLite3

public enum StoreError: Error, CustomStringConvertible {
    case open(String)
    case sql(String)

    public var description: String {
        switch self {
        case .open(let message): "Cannot open store: \(message)"
        case .sql(let message): "Store error: \(message)"
        }
    }
}

/// Local SQLite store. Plain SQLite3 (system library) was chosen over GRDB: no package fetch, so the
/// build makes no network call, and the schema is twelve small tables.
///
/// Metadata only (V-PRIV): paths, IDs, title-field values, timestamps, counters, states, and owner
/// preferences. No column holds message content, prompts, tool output, or credentials. Checkpoint
/// `state_json` holds the collector state structs; their keys are allowlisted in tests too.
public final class Store: @unchecked Sendable, CheckpointStore, NotificationLedgerStore, SummaryStoring {
    public let url: URL
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lighthouse", isDirectory: true)
            .appendingPathComponent("lighthouse.sqlite")
    }

    /// Every persisted table and column. `StoreTests` fails if the live schema differs (SPEC §11).
    public static let schemaAllowlist: [String: [String]] = [
        "checkpoints": ["path", "source", "device", "inode", "size", "offset", "mtime", "skipped_lines", "skipping_line", "state_json",
                        "last_read_at", "read_error"],
        "collector_status": ["source", "last_read_at", "thread_count", "files_indexed", "files_in_window", "files_not_indexed", "skipped_lines", "error"],
        "project_prefs": ["root", "pin_order", "paused", "archived"],
        "bindings": ["folder", "project_root"],
        "open_overrides": ["owning_app", "app_path", "app_name"],
        "usage_settings": ["key", "value"],
        "acknowledgements": ["incident", "acknowledged_at"],
        "notifications": ["incident", "project_root", "notified_at", "delivered", "attempts", "last_attempt_at", "notification_id"],
        "app_settings": ["key", "value"],
        // M8 (SPEC 2.9): summary text and its input hash only; never the request or conversation text.
        "summary_settings": ["key", "value"],
        "summaries": ["thread_id", "line1", "line2", "made_at", "activity_at", "input_hash", "provider", "model", "needs_owner", "continue_work"],
        "summary_calls": ["at"],
        // 0.0.13 (SPEC 2.11): nudge counts per thread run; no message text, no token.
        "nudges": ["thread_id", "episode_start", "count", "last_sent_at", "last_failed_at", "resting_since"],
    ]

    public init(url: URL = Store.defaultURL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            throw StoreError.open(String(cString: sqlite3_errmsg(db)))
        }
        try exec("""
        PRAGMA journal_mode = WAL;
        CREATE TABLE IF NOT EXISTS checkpoints (
            path TEXT NOT NULL, source TEXT NOT NULL, device INTEGER NOT NULL, inode INTEGER NOT NULL,
            size INTEGER NOT NULL, offset INTEGER NOT NULL, mtime REAL NOT NULL, skipped_lines INTEGER NOT NULL,
            skipping_line INTEGER NOT NULL, state_json TEXT NOT NULL, last_read_at REAL, read_error TEXT,
            PRIMARY KEY (source, path)
        );
        CREATE TABLE IF NOT EXISTS collector_status (
            source TEXT PRIMARY KEY, last_read_at REAL NOT NULL, thread_count INTEGER NOT NULL,
            files_indexed INTEGER NOT NULL, files_in_window INTEGER NOT NULL, files_not_indexed INTEGER NOT NULL,
            skipped_lines INTEGER NOT NULL, error TEXT
        );
        CREATE TABLE IF NOT EXISTS project_prefs (
            root TEXT PRIMARY KEY, pin_order INTEGER, paused INTEGER NOT NULL DEFAULT 0, archived INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS bindings (folder TEXT PRIMARY KEY, project_root TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS open_overrides (owning_app TEXT PRIMARY KEY, app_path TEXT NOT NULL, app_name TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS usage_settings (key TEXT PRIMARY KEY, value INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS acknowledgements (incident TEXT PRIMARY KEY, acknowledged_at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS notifications (incident TEXT PRIMARY KEY, project_root TEXT, notified_at REAL NOT NULL,
            delivered INTEGER NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, last_attempt_at REAL, notification_id TEXT);
        CREATE TABLE IF NOT EXISTS app_settings (key TEXT PRIMARY KEY, value INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS summary_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS summaries (thread_id TEXT PRIMARY KEY, line1 TEXT NOT NULL, line2 TEXT, made_at REAL NOT NULL,
            activity_at REAL NOT NULL, input_hash TEXT NOT NULL, provider TEXT NOT NULL, model TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS summary_calls (at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS nudges (thread_id TEXT PRIMARY KEY, episode_start REAL NOT NULL, count INTEGER NOT NULL,
            last_sent_at REAL, last_failed_at REAL, resting_since REAL);
        """)
        try migrate()
    }

    deinit { sqlite3_close(db) }

    /// Adds columns introduced after a store was created (M1 round 1: per-file read status).
    private func migrate() throws {
        var columns = Set<String>()
        try query("PRAGMA table_info(checkpoints)") { row in if let name = row.text(1) { columns.insert(name) } }
        if !columns.contains("last_read_at") { try exec("ALTER TABLE checkpoints ADD COLUMN last_read_at REAL;") }
        if !columns.contains("read_error") { try exec("ALTER TABLE checkpoints ADD COLUMN read_error TEXT;") }
        // M4 repair round 1: delivery state machine (`delivered` holds `DeliveryState`).
        var ledgerColumns = Set<String>()
        try query("PRAGMA table_info(notifications)") { row in if let name = row.text(1) { ledgerColumns.insert(name) } }
        if !ledgerColumns.contains("attempts") { try exec("ALTER TABLE notifications ADD COLUMN attempts INTEGER NOT NULL DEFAULT 0;") }
        if !ledgerColumns.contains("last_attempt_at") { try exec("ALTER TABLE notifications ADD COLUMN last_attempt_at REAL;") }
        // M9-E01: the identifier of the notification an attempt was claimed under.
        if !ledgerColumns.contains("notification_id") { try exec("ALTER TABLE notifications ADD COLUMN notification_id TEXT;") }
        // SPEC 2.10: the model's yes/no on whether the thread waits for the owner (no text).
        var summaryColumns = Set<String>()
        try query("PRAGMA table_info(summaries)") { row in if let name = row.text(1) { summaryColumns.insert(name) } }
        if !summaryColumns.contains("continue_work") { try exec("ALTER TABLE summaries ADD COLUMN continue_work INTEGER;") }
        if !summaryColumns.contains("needs_owner") { try exec("ALTER TABLE summaries ADD COLUMN needs_owner INTEGER;") }
    }

    /// Live schema as table → columns, for the allowlist test.
    public func schema() throws -> [String: [String]] {
        var tables: [String] = []
        try query("SELECT name FROM sqlite_master WHERE type = 'table'") { row in if let name = row.text(0) { tables.append(name) } }
        var result: [String: [String]] = [:]
        for table in tables {
            var columns: [String] = []
            try query("PRAGMA table_info(\(table))") { row in if let name = row.text(1) { columns.append(name) } }
            result[table] = columns
        }
        return result
    }

    /// Flushes the WAL into the main file (used by tests and the canary check).
    public func checkpointWAL() {
        try? exec("PRAGMA wal_checkpoint(TRUNCATE);")
    }

    // MARK: Checkpoints

    public func loadCheckpoints(source: SourceKind) -> [String: StoredCheckpoint] {
        var result: [String: StoredCheckpoint] = [:]
        try? query("SELECT path, device, inode, size, offset, mtime, skipped_lines, skipping_line, state_json, last_read_at, read_error FROM checkpoints WHERE source = ?",
                   [source.rawValue]) { row in
            guard let path = row.text(0), let state = row.text(8) else { return }
            result[path] = StoredCheckpoint(path: path, device: row.uint(1), inode: row.uint(2), size: row.uint(3), offset: row.uint(4),
                                            mtime: row.double(5), skippedLines: row.int(6) ?? 0, skippingLine: row.int(7) == 1,
                                            state: Data(state.utf8), lastReadAt: row.date(9)?.timeIntervalSince1970, readError: row.text(10))
        }
        return result
    }

    public func saveCheckpoints(source: SourceKind, changed: [StoredCheckpoint], removed: [String]) {
        do {
            try transaction {
                for path in removed {
                    try run("DELETE FROM checkpoints WHERE source = ? AND path = ?", [source.rawValue, path])
                }
                for c in changed {
                    try run("""
                        INSERT OR REPLACE INTO checkpoints (path, source, device, inode, size, offset, mtime, skipped_lines, skipping_line,
                        state_json, last_read_at, read_error) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, [c.path, source.rawValue, Int64(bitPattern: c.device), Int64(bitPattern: c.inode), Int64(c.size),
                              Int64(c.offset), c.mtime, c.skippedLines, c.skippingLine ? 1 : 0, String(decoding: c.state, as: UTF8.self),
                              c.lastReadAt, c.readError])
                }
            }
        } catch {
            // A failed save keeps the previous checkpoint; the next pass resumes from it.
        }
    }

    // MARK: Collector status

    public func saveStatuses(_ statuses: [CollectorStatus]) throws {
        try transaction {
            for s in statuses {
                try run("""
                    INSERT OR REPLACE INTO collector_status (source, last_read_at, thread_count, files_indexed, files_in_window,
                    files_not_indexed, skipped_lines, error) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, [s.source.rawValue, s.lastReadAt.timeIntervalSince1970, s.threadCount, s.filesIndexed,
                          s.filesInWindow, s.filesNotIndexed, s.skippedLines, s.error])
            }
        }
    }

    public func loadStatuses() throws -> [CollectorStatus] {
        var result: [CollectorStatus] = []
        try query("SELECT source, last_read_at, thread_count, files_indexed, files_in_window, files_not_indexed, skipped_lines, error FROM collector_status") { row in
            guard let source = SourceKind(rawValue: row.text(0) ?? "") else { return }
            result.append(CollectorStatus(source: source, lastReadAt: row.date(1) ?? .distantPast, threadCount: row.int(2) ?? 0,
                                          filesIndexed: row.int(3) ?? 0, filesInWindow: row.int(4) ?? 0, filesNotIndexed: row.int(5) ?? 0,
                                          skippedLines: row.int(6) ?? 0, error: row.text(7)))
        }
        return result
    }

    // MARK: Preferences

    public func loadPrefs() throws -> ProjectPrefs {
        var prefs = ProjectPrefs()
        var pins: [(Int, String)] = []
        try query("SELECT root, pin_order, paused, archived FROM project_prefs") { row in
            guard let root = row.text(0) else { return }
            if let order = row.int(1) { pins.append((order, root)) }
            if row.int(2) == 1 { prefs.paused.insert(root) }
            if row.int(3) == 1 { prefs.archived.insert(root) }
        }
        prefs.pinned = pins.sorted { $0.0 < $1.0 }.map(\.1)
        return prefs
    }

    public func savePrefs(_ prefs: ProjectPrefs) throws {
        try transaction {
            try exec("DELETE FROM project_prefs;")
            for root in Set(prefs.pinned).union(prefs.paused).union(prefs.archived) {
                try run("INSERT INTO project_prefs (root, pin_order, paused, archived) VALUES (?, ?, ?, ?)",
                        [root, prefs.pinned.firstIndex(of: root), prefs.paused.contains(root) ? 1 : 0, prefs.archived.contains(root) ? 1 : 0])
            }
        }
    }

    public func loadBindings() throws -> [ProjectBinding] {
        var result: [ProjectBinding] = []
        try query("SELECT folder, project_root FROM bindings") { row in
            if let folder = row.text(0), let root = row.text(1) { result.append(ProjectBinding(folder: folder, projectRoot: root)) }
        }
        return result
    }

    public func saveBinding(_ binding: ProjectBinding) throws {
        try run("INSERT OR REPLACE INTO bindings (folder, project_root) VALUES (?, ?)", [binding.folder, binding.projectRoot])
    }

    public func removeBinding(folder: String) throws {
        try run("DELETE FROM bindings WHERE folder = ?", [folder])
    }

    public func loadOverrides() throws -> [OwningApp: OpenOverride] {
        var result: [OwningApp: OpenOverride] = [:]
        try query("SELECT owning_app, app_path, app_name FROM open_overrides") { row in
            if let app = OwningApp(rawValue: row.text(0) ?? ""), let path = row.text(1), let name = row.text(2) {
                result[app] = OpenOverride(appPath: path, appName: name)
            }
        }
        return result
    }

    public func saveOverride(_ override: OpenOverride?, for app: OwningApp) throws {
        if let override {
            try run("INSERT OR REPLACE INTO open_overrides (owning_app, app_path, app_name) VALUES (?, ?, ?)", [app.rawValue, override.appPath, override.appName])
        } else {
            try run("DELETE FROM open_overrides WHERE owning_app = ?", [app.rawValue])
        }
    }

    // MARK: Acknowledgements (SPEC §5.4: incident identities hidden by the owner; persist across restart)

    public func loadAcknowledgements() throws -> Set<String> {
        var result = Set<String>()
        try query("SELECT incident FROM acknowledgements") { row in if let id = row.text(0) { result.insert(id) } }
        return result
    }

    public func acknowledge(_ incident: String, at date: Date = Date()) throws {
        try run("INSERT OR REPLACE INTO acknowledgements (incident, acknowledged_at) VALUES (?, ?)", [incident, date.timeIntervalSince1970])
    }

    // MARK: Nudges (SPEC 2.11)

    public func loadNudges() throws -> [String: NudgeRecord] {
        var result: [String: NudgeRecord] = [:]
        try query("SELECT thread_id, episode_start, count, last_sent_at, last_failed_at, resting_since FROM nudges") { row in
            guard let id = row.text(0), let start = row.date(1) else { return }
            result[id] = NudgeRecord(threadId: id, episodeStart: start, count: row.int(2) ?? 0, lastSentAt: row.date(3),
                                     lastFailedAt: row.date(4), restingSince: row.date(5))
        }
        return result
    }

    public func saveNudge(_ record: NudgeRecord) throws {
        try run("INSERT OR REPLACE INTO nudges (thread_id, episode_start, count, last_sent_at, last_failed_at, resting_since) VALUES (?, ?, ?, ?, ?, ?)",
                [record.threadId, record.episodeStart.timeIntervalSince1970, record.count, record.lastSentAt?.timeIntervalSince1970,
                 record.lastFailedAt?.timeIntervalSince1970, record.restingSince?.timeIntervalSince1970])
    }

    public func deleteNudge(_ threadId: String) throws {
        try run("DELETE FROM nudges WHERE thread_id = ?", [threadId])
    }

    // MARK: Notification ledger (SPEC §8: one notification per incident identity, across restart)

    /// Records of closed incidents are kept this long; an open incident keeps its record (M4-R04).
    public static let notificationRetention: TimeInterval = 30 * 24 * 3600

    public func loadNotificationLedger() throws -> [String: NotificationRecord] {
        var result: [String: NotificationRecord] = [:]
        try query("SELECT incident, project_root, notified_at, delivered, attempts, last_attempt_at, notification_id FROM notifications") { row in
            guard let id = row.text(0) else { return }
            result[id] = NotificationRecord(incident: id, projectRoot: row.text(1), at: row.date(2) ?? .distantPast,
                                            state: DeliveryState(rawValue: row.int(3) ?? 0) ?? .suppressed,
                                            attempts: row.int(4) ?? 0, lastAttemptAt: row.date(5), notificationId: row.text(6))
        }
        return result
    }

    public func writeNotificationRecords(_ records: [NotificationRecord], now: Date, keepingOpen open: Set<String>) throws {
        try transaction {
            for r in records {
                try run("""
                    INSERT OR REPLACE INTO notifications (incident, project_root, notified_at, delivered, attempts, last_attempt_at, notification_id)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, [r.incident, r.projectRoot, r.at.timeIntervalSince1970, r.state.rawValue, r.attempts, r.lastAttemptAt?.timeIntervalSince1970,
                          r.notificationId])
            }
            var expired: [String] = []
            try query("SELECT incident FROM notifications WHERE notified_at < ?", [now.timeIntervalSince1970 - Self.notificationRetention]) { row in
                if let id = row.text(0), !open.contains(id) { expired.append(id) }
            }
            for id in expired { try run("DELETE FROM notifications WHERE incident = ?", [id]) }
        }
    }

    // MARK: App settings (owner switches only)

    public func loadAppSettings() throws -> AppSettings {
        var values: [String: Int] = [:]
        try query("SELECT key, value FROM app_settings") { row in
            if let key = row.text(0), let value = row.int(1) { values[key] = value }
        }
        return AppSettings(values: values)
    }

    public func saveAppSettings(_ settings: AppSettings) throws {
        try transaction {
            for (key, value) in settings.values {
                try run("INSERT OR REPLACE INTO app_settings (key, value) VALUES (?, ?)", [key, value])
            }
        }
    }

    // MARK: Usage settings (owner switches only; readings and tokens are never stored)

    public func loadUsageSettings() throws -> UsageSettings {
        var values: [String: Int] = [:]
        try query("SELECT key, value FROM usage_settings") { row in
            if let key = row.text(0), let value = row.int(1) { values[key] = value }
        }
        return UsageSettings(values: values)
    }

    public func saveUsageSettings(_ settings: UsageSettings) throws {
        try transaction {
            for (key, value) in settings.values {
                try run("INSERT OR REPLACE INTO usage_settings (key, value) VALUES (?, ?)", [key, value])
            }
        }
    }

    // MARK: Summaries (M8): text, input hash and metadata; call times for the hourly cap

    public func loadSummarySettings() throws -> SummarySettings {
        var values: [String: String] = [:]
        try query("SELECT key, value FROM summary_settings") { row in
            if let key = row.text(0), let value = row.text(1) { values[key] = value }
        }
        return SummarySettings(values: values)
    }

    public func saveSummarySettings(_ settings: SummarySettings) throws {
        try transaction {
            for (key, value) in settings.values {
                try run("INSERT OR REPLACE INTO summary_settings (key, value) VALUES (?, ?)", [key, value])
            }
        }
    }

    public func loadSummaries() -> [String: ThreadSummary] {
        var result: [String: ThreadSummary] = [:]
        try? query("SELECT thread_id, line1, line2, made_at, activity_at, input_hash, provider, model, needs_owner, continue_work FROM summaries") { row in
            guard let id = row.text(0), let line1 = row.text(1), let made = row.date(3), let activity = row.date(4), let hash = row.text(5),
                  let provider = SummaryProvider(rawValue: row.text(6) ?? ""), let model = row.text(7) else { return }
            // Cleaned again on load, so summaries saved before a cleaning fix display correctly too.
            result[id] = ThreadSummary(threadId: id, line1: SummaryText.clean(Substring(line1)),
                                       line2: row.text(2).map { SummaryText.clean(Substring($0)) }.flatMap { $0.isEmpty ? nil : $0 }, madeAt: made, activityAt: activity, inputHash: hash,
                                       provider: provider, model: model, needsOwner: row.int(8).map { $0 == 1 }, continueWork: row.int(9).map { $0 == 1 })
        }
        return result
    }

    public func saveSummary(_ s: ThreadSummary) {
        try? run("""
            INSERT OR REPLACE INTO summaries (thread_id, line1, line2, made_at, activity_at, input_hash, provider, model, needs_owner, continue_work)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [s.threadId, s.line1, s.line2, s.madeAt.timeIntervalSince1970, s.activityAt.timeIntervalSince1970, s.inputHash,
                  s.provider.rawValue, s.model, s.needsOwner.map { $0 ? 1 : 0 }, s.continueWork.map { $0 ? 1 : 0 }])
    }

    public func deleteSummaries() {
        try? exec("DELETE FROM summaries;")
    }

    public func loadSummaryCalls(since: Date) -> [Date] {
        var result: [Date] = []
        try? query("SELECT at FROM summary_calls WHERE at >= ?", [since.timeIntervalSince1970]) { row in
            if let date = row.date(0) { result.append(date) }
        }
        return result
    }

    public func recordSummaryCall(at date: Date, pruneBefore: Date) {
        try? transaction {
            try run("DELETE FROM summary_calls WHERE at < ?", [pruneBefore.timeIntervalSince1970])
            try run("INSERT INTO summary_calls (at) VALUES (?)", [date.timeIntervalSince1970])
        }
    }

    // MARK: SQLite helpers

    struct Row {
        let statement: OpaquePointer?
        func text(_ index: Int32) -> String? {
            guard sqlite3_column_type(statement, index) != SQLITE_NULL, let c = sqlite3_column_text(statement, index) else { return nil }
            return String(cString: c)
        }
        func int(_ index: Int32) -> Int? {
            sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, index))
        }
        func uint(_ index: Int32) -> UInt64 { UInt64(bitPattern: sqlite3_column_int64(statement, index)) }
        func double(_ index: Int32) -> Double { sqlite3_column_double(statement, index) }
        func date(_ index: Int32) -> Date? {
            sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
        }
    }

    private func exec(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw StoreError.sql(message)
        }
    }

    /// Holds the lock for the whole transaction so statements from other threads cannot interleave.
    private func transaction(_ body: () throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        try exec("BEGIN IMMEDIATE;")
        do {
            try body()
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func run(_ sql: String, _ values: [Any?]) throws {
        try withStatement(sql, values) { statement in
            let code = sqlite3_step(statement)
            if code != SQLITE_DONE && code != SQLITE_ROW { throw StoreError.sql(String(cString: sqlite3_errmsg(db))) }
        }
    }

    private func query(_ sql: String, _ values: [Any?] = [], row: (Row) throws -> Void) throws {
        try withStatement(sql, values) { statement in
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { break }
                guard code == SQLITE_ROW else { throw StoreError.sql(String(cString: sqlite3_errmsg(db))) }
                try row(Row(statement: statement))
            }
        }
    }

    private func withStatement(_ sql: String, _ values: [Any?], _ body: (OpaquePointer?) throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw StoreError.sql(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case nil: sqlite3_bind_null(statement, index)
            case let v as String: sqlite3_bind_text(statement, index, v, -1, Self.transient)
            case let v as Int: sqlite3_bind_int64(statement, index, Int64(v))
            case let v as Int64: sqlite3_bind_int64(statement, index, v)
            case let v as Double: sqlite3_bind_double(statement, index, v)
            default: sqlite3_bind_null(statement, index)
            }
        }
        try body(statement)
    }
}
