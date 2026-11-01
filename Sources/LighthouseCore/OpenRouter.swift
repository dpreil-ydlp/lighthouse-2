import Foundation

/// An app Lighthouse can hand off to. Bundle IDs as each app's Info.plist declares them.
public struct TargetApp: Sendable, Hashable, Codable {
    public var name: String
    public var bundleIdentifier: String

    public init(name: String, bundleIdentifier: String) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
    }

    public static let t3Code = TargetApp(name: "T3 Code", bundleIdentifier: "com.t3tools.t3code")
    public static let chatGPT = TargetApp(name: "ChatGPT", bundleIdentifier: "com.openai.codex")
    public static let claude = TargetApp(name: "Claude", bundleIdentifier: "com.anthropic.claudefordesktop")

    public static func forOwner(_ app: OwningApp) -> TargetApp {
        switch app {
        case .t3: .t3Code
        case .codex: .chatGPT
        case .claudeCode: .claude
        }
    }
}

/// Recorded routing capability per owning app (SPEC §7).
public enum RoutingCapability: String, Sendable, Hashable, Codable {
    /// A link proven (two threads, cold and warm, no new turn) to land on the exact thread.
    case exactThread
    /// Only the app can be opened; the session ID is offered separately.
    case appOnly
}

public struct RoutingCapabilities: Sendable, Hashable, Codable {
    public var t3: RoutingCapability
    public var codex: RoutingCapability
    public var claudeCode: RoutingCapability

    public init(t3: RoutingCapability, codex: RoutingCapability, claudeCode: RoutingCapability) {
        self.t3 = t3
        self.codex = codex
        self.claudeCode = claudeCode
    }

    public subscript(app: OwningApp) -> RoutingCapability {
        switch app {
        case .t3: t3
        case .codex: codex
        case .claudeCode: claudeCode
        }
    }

    /// Recorded for this build.
    /// T3: `t3code://threads/<env>/<thread>` proven on T3 Code 0.1.5 on two threads, cold and warm,
    /// with no new turn, so exactThread.
    /// A T3 thread without environment or thread IDs still falls back to "Open T3 Code app".
    /// Codex: `codex://threads/<id>` warm-proven on two threads; the cold proof is not recorded, so appOnly.
    /// Claude: no passive route known (`claude://code/continue` resumes a session and is forbidden).
    public static let recorded = RoutingCapabilities(t3: .exactThread, codex: .appOnly, claudeCode: .appOnly)
}

/// What a UI action does. The router builds navigation handoffs only (V-OBS): open an app or link,
/// open a folder in an app, reveal a folder, copy a reference. It never builds a command or a message.
public enum OpenAction: Sendable, Hashable {
    /// A proven link to the exact thread.
    case link(URL, app: TargetApp)
    /// Open the app only. The session ID is copied by a separate action.
    case app(TargetApp, sessionId: String)
    /// Owner override (Settings › Open-in): `open -a <app> <cwd>`.
    case appWithFolder(appPath: String, appName: String, folder: String, sessionId: String)
    case reveal(path: String)

    public var appName: String {
        switch self {
        case .link(_, let app), .app(let app, _): app.name
        case .appWithFolder(_, let name, _, _): name
        case .reveal: "Finder"
        }
    }

    /// SPEC §7: only exact-thread links say "Open in X ↗"; app-only says "Open X app".
    public var label: String {
        switch self {
        case .link: "Open in \(appName) ↗"
        case .app, .appWithFolder: "Open \(appName) app"
        case .reveal: "Reveal in Finder"
        }
    }

    public var isExactThread: Bool {
        if case .link = self { return true }
        return false
    }

    /// Session ID offered by the separate "Copy session ID" action.
    public var sessionId: String? {
        switch self {
        case .app(_, let id), .appWithFolder(_, _, _, let id): id
        case .link, .reveal: nil
        }
    }
}

/// Per-owning-app override chosen in Settings › Open-in. Changes only the app opened.
public struct OpenOverride: Sendable, Hashable, Codable {
    public var appPath: String
    public var appName: String

    public init(appPath: String, appName: String) {
        self.appPath = appPath
        self.appName = appName
    }
}

public struct OpenRouter: Sendable {
    public var capabilities: RoutingCapabilities
    public var overrides: [OwningApp: OpenOverride]

    public init(capabilities: RoutingCapabilities = .recorded, overrides: [OwningApp: OpenOverride] = [:]) {
        self.capabilities = capabilities
        self.overrides = overrides
    }

    /// The target for one thread. `owningApp` decides, not the model or provider (SPEC §7).
    public func target(for thread: SessionThread) -> OpenAction {
        if let override = overrides[thread.owningApp] {
            return .appWithFolder(appPath: override.appPath, appName: override.appName, folder: thread.cwd, sessionId: thread.sessionId)
        }
        let app = TargetApp.forOwner(thread.owningApp)
        guard capabilities[thread.owningApp] == .exactThread, let url = Self.link(for: thread) else {
            return .app(app, sessionId: thread.sessionId)
        }
        return .link(url, app: app)
    }

    static func link(for thread: SessionThread) -> URL? {
        switch thread.owningApp {
        case .t3:
            guard let env = thread.t3EnvironmentId, let id = thread.t3ThreadId else { return nil }
            return t3URL(environmentId: env, threadId: id)
        case .codex:
            return thread.providerIdentities.first { $0.provider == .codex }.flatMap { codexURL(threadId: $0.nativeId) }
        case .claudeCode:
            return nil
        }
    }

    /// Project "Open ↗": the most recently active thread's target, or Reveal in Finder when the
    /// project has no threads (SPEC §7).
    public func primaryTarget(for project: ProjectSummary) -> (action: OpenAction, thread: SessionThread?) {
        guard let thread = project.mostRecentThread else { return (.reveal(path: project.identity.folderPath), nil) }
        return (target(for: thread), thread)
    }

    /// Context-menu "Open in …" entries: one per distinct app the project has, most recent first.
    public func allTargets(for project: ProjectSummary) -> [(action: OpenAction, thread: SessionThread)] {
        var seen = Set<String>()
        var result: [(OpenAction, SessionThread)] = []
        for thread in project.threads.sorted(by: { $0.latestActivityAt > $1.latestActivityAt }) {
            let action = target(for: thread)
            if seen.insert(action.appName).inserted { result.append((action, thread)) }
        }
        return result
    }

    // MARK: Link formats

    /// T3 Code deep-link format, IDs URL-encoded.
    public static func t3URL(environmentId: String, threadId: String) -> URL? {
        guard let env = encode(environmentId), let id = encode(threadId) else { return nil }
        return URL(string: "t3code://threads/\(env)/\(id)")
    }

    /// Built by ChatGPT.app for a local thread link (`codex://threads/${conversationId}`, app bundle JS).
    public static func codexURL(threadId: String) -> URL? {
        guard let id = encode(threadId) else { return nil }
        return URL(string: "codex://threads/\(id)")
    }

    /// Link schemes and hosts that start or resume a turn. Never built (V-OBS).
    public static let forbiddenLinkPrefixes = ["claude://code/continue", "claude://code/new", "claude://resume", "claude://claude.ai/new"]

    private static func encode(_ value: String) -> String? {
        guard !value.isEmpty else { return nil }
        return value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.")))
    }
}
