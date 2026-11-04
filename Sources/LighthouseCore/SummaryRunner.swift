import Darwin
import Foundation

/// One CLI invocation. The request text is never part of it: it goes to standard input only.
public struct SummaryCommand: Sendable, Hashable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var directory: String

    public init(executable: String, arguments: [String], environment: [String: String], directory: String) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.directory = directory
    }
}

/// What a finished (or refused) process left behind. Standard error is counted, never kept.
public struct ProcessOutcome: Sendable, Hashable {
    public var launched: Bool
    public var exitCode: Int32?
    public var timedOut: Bool
    public var stdout: Data
    public var stderrBytes: Int
    public var seconds: Double

    public init(launched: Bool, exitCode: Int32?, timedOut: Bool, stdout: Data, stderrBytes: Int, seconds: Double) {
        self.launched = launched
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.stdout = stdout
        self.stderrBytes = stderrBytes
        self.seconds = seconds
    }

    public static let notLaunched = ProcessOutcome(launched: false, exitCode: nil, timedOut: false, stdout: Data(), stderrBytes: 0, seconds: 0)
}

/// Starts summary CLIs, and `/usr/bin/security` for the Claude credential (`ClaudeKeychainCredentials`).
/// The only process-launch path in Lighthouse (tested in `SummaryTests`).
public protocol SummaryProcessLauncher: Sendable {
    func run(_ command: SummaryCommand, input: Data, timeout: TimeInterval) async -> ProcessOutcome
}

/// Foundation `Process` with pipes: standard input gets the request and is closed; standard output
/// is kept up to `stdoutLimit` bytes; standard error is drained and only counted. After `timeout`
/// the process gets SIGTERM, then SIGKILL 2 s later.
public struct SystemProcessLauncher: SummaryProcessLauncher {
    public static let stdoutLimit = 256 * 1024

    public init() {}

    public func run(_ command: SummaryCommand, input: Data, timeout: TimeInterval) async -> ProcessOutcome {
        // Dedicated threads, not the shared dispatch pool: the waits below block, and a starved pool
        // must never delay the timeout.
        await withCheckedContinuation { continuation in
            Thread { continuation.resume(returning: Self.runBlocking(command, input: input, timeout: timeout)) }.start()
        }
    }

    /// Starts a process that outlives the app (the update install script, SPEC 2.12): no pipes, no
    /// wait. True when it started.
    public static func launchDetached(executable: String, arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        return true
    }

    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var stdout = Data()
        var stderrBytes = 0
    }

    static func runBlocking(_ command: SummaryCommand, input: Data, timeout: TimeInterval) -> ProcessOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.environment = command.environment
        process.currentDirectoryURL = URL(fileURLWithPath: command.directory, isDirectory: true)
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        let started = DispatchTime.now().uptimeNanoseconds
        do { try process.run() } catch { return .notLaunched }

        let box = Box()
        let outDone = DispatchSemaphore(value: 0), errDone = DispatchSemaphore(value: 0)
        let outHandle = stdout.fileHandleForReading, errHandle = stderr.fileHandleForReading, inHandle = stdin.fileHandleForWriting
        Thread {
            while true {
                let chunk = outHandle.availableData
                if chunk.isEmpty { break }
                box.lock.withLock { if box.stdout.count < stdoutLimit { box.stdout.append(chunk.prefix(stdoutLimit - box.stdout.count)) } }
            }
            outDone.signal()
        }.start()
        Thread {
            while true {
                let chunk = errHandle.availableData
                if chunk.isEmpty { break }
                box.lock.withLock { box.stderrBytes += chunk.count }
            }
            errDone.signal()
        }.start()
        Thread {
            try? inHandle.write(contentsOf: input)
            try? inHandle.close()
        }.start()
        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                exited.wait()
            }
        }
        // A grandchild may keep the pipes open; do not wait on it past 2 s.
        _ = outDone.wait(timeout: .now() + 2)
        _ = errDone.wait(timeout: .now() + 2)
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
        return box.lock.withLock {
            ProcessOutcome(launched: true, exitCode: process.terminationStatus, timedOut: timedOut, stdout: box.stdout,
                           stderrBytes: box.stderrBytes, seconds: seconds)
        }
    }
}

/// Finds the installed CLIs. A GUI app has no login-shell PATH, so the usual install folders are
/// checked in order. Nothing is installed or downloaded.
public struct CLILocator: Sendable {
    public var home: String
    public var candidates: @Sendable (SummaryProvider, String) -> [String]

    public init(home: String = NSHomeDirectory(), candidates: (@Sendable (SummaryProvider, String) -> [String])? = nil) {
        self.home = home
        self.candidates = candidates ?? Self.standardCandidates
    }

    @Sendable public static func standardCandidates(_ provider: SummaryProvider, home: String) -> [String] {
        switch provider {
        case .off: []
        case .claude: ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                       "\(home)/.npm-global/bin/claude", "\(home)/.bun/bin/claude"]
        case .chatgpt: ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(home)/.local/bin/codex", "\(home)/.npm-global/bin/codex",
                        "\(home)/.bun/bin/codex"]
        }
    }

    public func locate(_ provider: SummaryProvider) -> String? {
        candidates(provider, home).first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// The two CLI runners (contract M8 A3): no visible session, no tools, no MCP servers, no hooks,
/// an empty scratch folder as working directory, and a minimal environment.
public enum SummaryCLI {
    /// Codex feature switches turned off for a summary call (checked with `codex features list`,
    /// codex-cli 0.165.0). `code_mode_host` off makes every code-mode tool fail closed; the models
    /// Lighthouse uses expose their tools only through code mode (`tool_mode: code_mode_only`).
    public static let codexDisabledFeatures = [
        "shell_tool", "code_mode_host", "code_mode_interrupt", "hooks", "memories", "multi_agent", "apps", "plugins", "remote_plugin",
        "view_image", "image_generation", "sleep_tool", "goals", "browser_use", "computer_use", "in_app_browser", "daemon_auto_start",
        "shell_snapshot", "skill_search", "skill_mcp_dependency_install", "tool_suggest", "chronicle", "workspace_dependencies",
        "collaboration_modes",
    ]

    public static func environment(home: String, executable: String) -> [String: String] {
        let user = NSUserName()
        let folder = (executable as NSString).deletingLastPathComponent
        var path = [folder, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        path = path.filter { seen.insert($0).inserted }
        return ["HOME": home, "USER": user, "LOGNAME": user, "PATH": path.joined(separator: ":"), "TMPDIR": NSTemporaryDirectory(),
                "LANG": "en_US.UTF-8", "NO_COLOR": "1", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "DISABLE_AUTOUPDATER": "1"]
    }

    public static func command(provider: SummaryProvider, model: String, executable: String, scratch: String, home: String) -> SummaryCommand? {
        guard SummarySettings.validModel(model) else { return nil }
        let env = environment(home: home, executable: executable)
        switch provider {
        case .off:
            return nil
        case .claude:
            // `--bare` is not used: it never reads OAuth or the Keychain, so a subscription login fails.
            return SummaryCommand(executable: executable, arguments: [
                "-p", "--model", model, "--no-session-persistence", "--safe-mode", "--tools", "", "--strict-mcp-config",
                "--setting-sources", "", "--disable-slash-commands", "--system-prompt", SummaryRequest.instructions,
                "--output-format", "json",
            ], environment: env, directory: scratch)
        case .chatgpt:
            var arguments = ["exec", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules", "-C", scratch,
                             "-m", model, "-s", "read-only", "--color", "never",
                             "-c", "approval_policy=\"never\"", "-c", "model_reasoning_effort=\"low\"", "-c", "web_search=\"disabled\"",
                             "-c", "instructions=\(tomlString(SummaryRequest.instructions))",
                             "-c", "include_collaboration_mode_instructions=false", "-c", "include_permissions_instructions=false",
                             "-c", "include_environment_context=false", "-c", "skills.include_instructions=false",
                             "-c", "include_apps_instructions=false"]
            for feature in codexDisabledFeatures { arguments += ["--disable", feature] }
            arguments += ["--json", "-"]
            return SummaryCommand(executable: executable, arguments: arguments, environment: env, directory: scratch)
        }
    }

    static func tomlString(_ text: String) -> String {
        var escaped = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\t": escaped += "\\t"
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return "\"\(escaped)\""
    }

    /// The model's final answer, or nil when the CLI reported an error or said nothing.
    public static func answer(provider: SummaryProvider, stdout: Data) -> String? {
        switch provider {
        case .off:
            return nil
        case .claude:
            // `--output-format json`: one object with `result` and `is_error`.
            guard let object = (try? JSONSerialization.jsonObject(with: stdout)) as? [String: Any],
                  object["is_error"] as? Bool != true, object["subtype"] as? String ?? "success" == "success",
                  let result = object["result"] as? String else { return nil }
            return result
        case .chatgpt:
            // `--json`: one event per line; the last `agent_message` item is the answer.
            var answer: String?
            var failed = false
            for line in stdout.split(separator: UInt8(ascii: "\n")) {
                guard let event = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
                if event["type"] as? String == "turn.failed" || event["type"] as? String == "error" { failed = true }
                if event["type"] as? String == "item.completed", let item = event["item"] as? [String: Any],
                   item["type"] as? String == "agent_message", let text = item["text"] as? String {
                    answer = text
                }
            }
            return failed ? nil : answer
        }
    }
}
