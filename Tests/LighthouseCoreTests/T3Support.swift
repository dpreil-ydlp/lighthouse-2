import Foundation
import SQLite3
@testable import LighthouseCore

/// A scratch T3 home with a WAL-mode `statev2.sqlite` built from test data (never live state).
/// macOS SQLite keeps the `-wal` and `-shm` sidecars after the last connection closes (persistent
/// WAL), as on a Mac where T3 is not running. `close()` the in-process writer before a read whose
/// file bytes are checked: connections in one process share one shared-memory mapping, so only a
/// writer in another process (`ExternalWriter`) models a running T3. Text columns (prompt, result, request payload, messages) hold the body
/// canary so tests can prove the reader never selects them.
final class T3Fixture {
    let home: String
    var databasePath: String { home + "/userdata/statev2.sqlite" }
    private var db: OpaquePointer?
    static let environmentId = "env-test-1"

    init(_ scratch: Scratch, environmentId: String? = T3Fixture.environmentId) {
        home = scratch.dir("t3")
        _ = scratch.dir("t3/userdata")
        if let environmentId { scratch.write("t3/userdata/environment-id", environmentId + "\n") }
        precondition(sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
        exec("""
        PRAGMA journal_mode = WAL;
        CREATE TABLE projection_projects (project_id TEXT PRIMARY KEY, title TEXT NOT NULL, workspace_root TEXT NOT NULL,
          scripts_json TEXT NOT NULL DEFAULT '[]', created_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT '', deleted_at TEXT);
        CREATE TABLE orchestration_v2_projection_threads (thread_id TEXT PRIMARY KEY, project_id TEXT NOT NULL, title TEXT NOT NULL,
          default_provider TEXT NOT NULL DEFAULT 'codex', runtime_mode TEXT NOT NULL DEFAULT 'full-access', interaction_mode TEXT NOT NULL DEFAULT 'default',
          active_provider_thread_id TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, archived_at TEXT, deleted_at TEXT,
          payload_json TEXT NOT NULL, provider_instance_id TEXT);
        CREATE TABLE orchestration_v2_projection_provider_threads (provider_thread_id TEXT PRIMARY KEY, thread_id TEXT, owner_node_id TEXT,
          provider TEXT NOT NULL, provider_session_id TEXT, status TEXT NOT NULL DEFAULT 'idle', first_run_ordinal INTEGER, last_run_ordinal INTEGER,
          updated_at TEXT NOT NULL DEFAULT '', payload_json TEXT NOT NULL, driver TEXT, provider_instance_id TEXT);
        CREATE TABLE orchestration_v2_projection_runs (run_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, ordinal INTEGER NOT NULL,
          provider TEXT NOT NULL DEFAULT 'codex', provider_thread_id TEXT, status TEXT NOT NULL, requested_at TEXT NOT NULL, completed_at TEXT,
          payload_json TEXT NOT NULL DEFAULT '{}', provider_instance_id TEXT);
        CREATE UNIQUE INDEX runs_thread_ordinal ON orchestration_v2_projection_runs(thread_id, ordinal);
        CREATE TABLE orchestration_v2_projection_runtime_requests (runtime_request_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL,
          node_id TEXT NOT NULL DEFAULT 'n', provider_turn_id TEXT, kind TEXT NOT NULL, status TEXT NOT NULL, created_at TEXT NOT NULL,
          resolved_at TEXT, payload_json TEXT NOT NULL);
        CREATE TABLE orchestration_v2_projection_subagents (subagent_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, run_id TEXT,
          parent_node_id TEXT NOT NULL DEFAULT 'n', provider TEXT NOT NULL, provider_thread_id TEXT, child_thread_id TEXT, origin TEXT NOT NULL DEFAULT 'app_owned',
          status TEXT NOT NULL, started_at TEXT, completed_at TEXT, updated_at TEXT NOT NULL, payload_json TEXT NOT NULL, driver TEXT, provider_instance_id TEXT);
        CREATE TABLE orchestration_v2_projection_messages (message_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, text TEXT NOT NULL);
        """)
    }

    deinit { close() }

    /// Closes the writer, like T3 quitting cleanly: SQLite checkpoints and removes the sidecars.
    func close() {
        if let db { sqlite3_close_v2(db) }
        db = nil
    }

    func exec(_ sql: String) {
        if db == nil { precondition(sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK) }
        var error: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(db, sql, nil, nil, &error)
        precondition(code == SQLITE_OK, error.map { String(cString: $0) } ?? "exec failed")
    }

    /// Removes sidecars by name (`-wal`, `-shm`) after closing the writer.
    func remove(_ suffixes: String...) {
        close()
        for suffix in suffixes { try? FileManager.default.removeItem(atPath: databasePath + suffix) }
    }

    static func q(_ value: String?) -> String {
        guard let value else { return "NULL" }
        return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    func project(_ id: String, title: String, root: String) {
        exec("INSERT INTO projection_projects (project_id, title, workspace_root) VALUES (\(Self.q(id)), \(Self.q(title)), \(Self.q(root)))")
    }

    func thread(_ id: String, project: String, title: String, created: Date, parent: String? = nil, worktree: String? = nil,
                archived: Bool = false) {
        let lineage = parent.map { #"{"parentThreadId":"\#($0)","relationshipToParent":"subagent","rootThreadId":"\#($0)"}"# }
            ?? #"{"parentThreadId":null,"relationshipToParent":null}"#
        let payload = #"{"id":"\#(id)","title":"\#(title)","worktreePath":\#(worktree.map { "\"\($0)\"" } ?? "null"),"lineage":\#(lineage),"note":"\#(Fixture.bodyCanary)"}"#
        let stamp = Self.iso(created)
        exec("""
            INSERT INTO orchestration_v2_projection_threads (thread_id, project_id, title, created_at, updated_at, archived_at, payload_json)
            VALUES (\(Self.q(id)), \(Self.q(project)), \(Self.q(title)), '\(stamp)', '\(stamp)', \(archived ? "'\(stamp)'" : "NULL"), \(Self.q(payload)))
            """)
        exec("INSERT INTO orchestration_v2_projection_messages VALUES ('m-\(id)', \(Self.q(id)), '\(Fixture.bodyCanary) \(Fixture.secretCanary)')")
    }

    /// T3's settle (SPEC 2.14): `settledOverride` 'settled' and `settledAt` in the thread payload.
    func settle(_ id: String, at time: Date) {
        exec("""
            UPDATE orchestration_v2_projection_threads SET payload_json = json_set(payload_json,
              '$.settledOverride', 'settled', '$.settledAt', '\(Self.iso(time))') WHERE thread_id = \(Self.q(id))
            """)
    }

    /// T3's unsettle: the override is cleared and `unsettledAt` set; the old `settledAt` may remain.
    func unsettle(_ id: String, at time: Date) {
        exec("""
            UPDATE orchestration_v2_projection_threads SET payload_json = json_set(payload_json,
              '$.settledOverride', json('null'), '$.unsettledAt', '\(Self.iso(time))') WHERE thread_id = \(Self.q(id))
            """)
    }

    func mapping(thread: String, driver: String, nativeId: String) {
        let payload = #"{"nativeThreadRef":{"driver":"\#(driver)","nativeId":"\#(nativeId)","strength":"strong"},"goal":"\#(Fixture.bodyCanary)"}"#
        exec("""
            INSERT INTO orchestration_v2_projection_provider_threads (provider_thread_id, thread_id, provider, payload_json)
            VALUES ('pt-\(nativeId)', \(Self.q(thread)), \(Self.q(driver)), \(Self.q(payload)))
            """)
    }

    func run(thread: String, ordinal: Int, status: String, requested: Date, completed: Date? = nil) {
        exec("""
            INSERT INTO orchestration_v2_projection_runs (run_id, thread_id, ordinal, status, requested_at, completed_at)
            VALUES ('run-\(thread)-\(ordinal)', \(Self.q(thread)), \(ordinal), \(Self.q(status)), '\(Self.iso(requested))', \(Self.q(completed.map(Self.iso))))
            """)
    }

    func request(_ id: String, thread: String, kind: String, status: String = "pending", created: Date) {
        let payload = #"{"kind":"\#(kind)","question":"\#(Fixture.bodyCanary) \#(Fixture.secretCanary)"}"#
        exec("""
            INSERT INTO orchestration_v2_projection_runtime_requests (runtime_request_id, thread_id, kind, status, created_at, payload_json)
            VALUES (\(Self.q(id)), \(Self.q(thread)), \(Self.q(kind)), \(Self.q(status)), '\(Self.iso(created))', \(Self.q(payload)))
            """)
    }

    func subagent(_ id: String, parent: String, child: String, provider: String, status: String, started: Date, updated: Date,
                  completed: Date? = nil) {
        let payload = #"{"prompt":"\#(Fixture.bodyCanary)","result":"\#(Fixture.secretCanary)"}"#
        exec("""
            INSERT INTO orchestration_v2_projection_subagents (subagent_id, thread_id, provider, child_thread_id, status, started_at,
              completed_at, updated_at, payload_json)
            VALUES (\(Self.q(id)), \(Self.q(parent)), \(Self.q(provider)), \(Self.q(child)), \(Self.q(status)), '\(Self.iso(started))',
              \(Self.q(completed.map(Self.iso))), '\(Self.iso(updated))', \(Self.q(payload)))
            """)
    }
}

/// A monotonic clock that advances `step` seconds on every reading (deadline tests).
final class SteppingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double = 0
    let step: Double
    init(step: Double) { self.step = step }
    func read() -> Double {
        lock.lock(); defer { lock.unlock() }
        value += step
        return value
    }
}

/// A running T3 stand-in: `/usr/bin/sqlite3` in its own process holds the database open after a
/// write, so its WAL and shared memory are live while Lighthouse reads.
final class ExternalWriter {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var counter = 0

    init(database: String) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    /// Runs `sql` in the writer process and waits until it has finished.
    func run(_ sql: String) {
        counter += 1
        let marker = "ready-\(counter)"
        input.fileHandleForWriting.write(Data("\(sql);\nSELECT '\(marker)';\n".utf8))
        var seen = ""
        while !seen.contains(marker) {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            seen += String(decoding: chunk, as: UTF8.self)
        }
    }

    func stop() {
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
    }

    deinit { if process.isRunning { stop() } }
}

/// File access modes of one process's descriptors from `lsof -F an` (`r` read, `w` write, `u` both).
/// A descriptor opened read-only cannot back a writable shared mapping.
final class OpenModes: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var files: [String: String] = [:]

    func capture(pid: Int32, matching: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-n", "-P", "-a", "-p", String(pid), "-F", "an"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var mode: String?
        var result: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            // Memory-mapped entries carry no access mode (blank); only descriptors are compared.
            if line.hasPrefix("a") { mode = line.dropFirst().trimmingCharacters(in: .whitespaces).isEmpty ? nil : String(line.dropFirst()) }
            if line.hasPrefix("n"), line.contains(matching), let mode {
                let path = ProjectResolver.standardize(String(line.dropFirst()))
                result[path] = (result[path].map { $0 == mode ? $0 : "u" }) ?? mode
            }
        }
        lock.lock(); files = result; lock.unlock()
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
