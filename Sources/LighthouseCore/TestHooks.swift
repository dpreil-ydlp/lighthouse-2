import Foundation

/// Launch-only test configuration for live UI checks on scratch data (M1-07).
///
/// Values come only from the process argument list (`-LighthouseTestStore <path>` etc.), never from
/// `UserDefaults`, so a saved preference can never redirect a normal launch. Test mode needs all
/// three scratch destinations; any other combination is rejected before a store is opened, so
/// fixture sources can never be mixed with the real store or real sources with a scratch store.
public enum TestHooks: Equatable, Sendable {
    case normal
    case test(store: URL, claudeRoot: String, codexHome: String)
    case rejected(reason: String)

    public static let storeFlag = "-LighthouseTestStore"
    public static let claudeFlag = "-LighthouseTestClaudeRoot"
    public static let codexFlag = "-LighthouseTestCodexHome"
    static let flags = [storeFlag, claudeFlag, codexFlag]

    /// - Parameters:
    ///   - arguments: the process argument list (`CommandLine.arguments`).
    ///   - realStore: the normal store location; a test store may not point at it.
    public static func parse(arguments: [String], realStore: URL = Store.defaultURL) -> TestHooks {
        var values: [String: String] = [:]
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            if flags.contains(argument) {
                let next = arguments.index(after: index)
                guard next < arguments.endIndex, !arguments[next].hasPrefix("-") else {
                    return .rejected(reason: "\(argument) has no value")
                }
                guard values[argument] == nil else { return .rejected(reason: "\(argument) given twice") }
                values[argument] = arguments[next]
                index = arguments.index(after: next)
            } else {
                index = arguments.index(after: index)
            }
        }
        guard !values.isEmpty else { return .normal }
        let missing = flags.filter { values[$0] == nil }
        guard missing.isEmpty else {
            return .rejected(reason: "partial test configuration; missing \(missing.joined(separator: ", "))")
        }
        let store = values[storeFlag]!, claude = values[claudeFlag]!, codex = values[codexFlag]!
        for path in [store, claude, codex] where !path.hasPrefix("/") {
            return .rejected(reason: "test paths must be absolute: \(path)")
        }
        let storeURL = URL(fileURLWithPath: store).standardizedFileURL
        guard storeURL.path != realStore.standardizedFileURL.path,
              storeURL.deletingLastPathComponent().path != realStore.deletingLastPathComponent().standardizedFileURL.path else {
            return .rejected(reason: "test store may not use the real store folder")
        }
        return .test(store: storeURL, claudeRoot: claude, codexHome: codex)
    }
}

extension TestHooks {
    public static let t3Flag = "-LighthouseTestT3Home"

    /// A scratch T3 home for live UI checks (M4-R07), from the argument list only. Honoured only in
    /// complete test mode, as an absolute path outside the real `~/.t3`; otherwise nil, so test
    /// sources never read the real T3 database and real sources never read a scratch one.
    public static func scratchT3Home(arguments: [String], realT3Home: String = NSHomeDirectory() + "/.t3",
                                     realStore: URL = Store.defaultURL) -> String? {
        guard case .test = parse(arguments: arguments, realStore: realStore),
              let index = arguments.firstIndex(of: t3Flag), index + 1 < arguments.count else { return nil }
        let path = URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL.path
        let real = URL(fileURLWithPath: realT3Home).standardizedFileURL.path
        guard arguments[index + 1].hasPrefix("/"), path != real, !path.hasPrefix(real + "/") else { return nil }
        // The path as given: standardizing turns /private/tmp into /tmp, a symlinked ancestor that the
        // read-only source boundary refuses.
        return arguments[index + 1]
    }
}

extension TestHooks {
    public static let usageFlag = "-LighthouseTestUsage"

    /// Canned usage readings for receipt snapshots (M6 C3), from the argument list only. Honoured
    /// only in complete test mode; the live usage monitor is then not started, so no credential is
    /// read and no request is made. Nil otherwise or for an unknown fixture name.
    public static func usageFixture(arguments: [String], now: Date, realStore: URL = Store.defaultURL) -> [ProviderUsage]? {
        guard case .test = parse(arguments: arguments, realStore: realStore),
              let index = arguments.firstIndex(of: usageFlag), index + 1 < arguments.count else { return nil }
        return UsageFixtures.named(arguments[index + 1], now: now)
    }
}

extension TestHooks {
    public static let summariesFlag = "-LighthouseTestSummaries"

    /// Turns summaries on for receipt runs (M8 C4), from the argument list only, and only in complete
    /// test mode (scratch store and scratch sources). Nil otherwise or for an unknown provider.
    public static func summaryProvider(arguments: [String], realStore: URL = Store.defaultURL) -> SummaryProvider? {
        guard case .test = parse(arguments: arguments, realStore: realStore),
              let index = arguments.firstIndex(of: summariesFlag), index + 1 < arguments.count,
              let provider = SummaryProvider(rawValue: arguments[index + 1]), provider != .off else { return nil }
        return provider
    }
}

extension TestHooks {
    public static let updateFeedFlag = "-LighthouseTestUpdateFeed"

    /// A local release list (a JSON file in the GitHub format) for update checks (SPEC 2.12), from
    /// the argument list only, and only in complete test mode. Its assets may be `file://` URLs.
    /// Nil otherwise: a normal launch always reads the real release list.
    public static func updateFeed(arguments: [String], realStore: URL = Store.defaultURL) -> URL? {
        guard case .test = parse(arguments: arguments, realStore: realStore),
              let index = arguments.firstIndex(of: updateFeedFlag), index + 1 < arguments.count,
              arguments[index + 1].hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: arguments[index + 1])
    }
}

/// Fixture readings relative to `now` (M6 contract C1 cases a and b, plus a session window).
public enum UsageFixtures {
    public static func named(_ name: String, now: Date) -> [ProviderUsage]? {
        switch name {
        case "pace": pace(now: now)
        default: nil
        }
    }

    /// Claude session 70 % used, 3 h into 5 h (deficit, runs out before reset); Claude week 16.67 %
    /// used, 1 d into 7 d (case a); Codex week 10 % used, 3.5 d into 7 d (case b, reserve).
    public static func pace(now: Date) -> [ProviderUsage] {
        let hour: TimeInterval = 3600, day: TimeInterval = 86400
        func reading(_ provider: Provider, plan: String, account: String, _ windows: [UsageWindow]) -> ProviderUsage {
            ProviderUsage(provider: provider, accountId: account, plan: plan, windows: windows, lastAttemptAt: now,
                          lastSuccessAt: now, lastFailure: nil, status: .fresh, source: "Fixture (test mode)")
        }
        return [
            reading(.claude, plan: "max", account: "fixture-claude-0001", [
                UsageWindow(id: UsageWindow.sessionId, label: "session", duration: 5 * hour, usedPercent: 70, resetsAt: now.addingTimeInterval(2 * hour)),
                UsageWindow(id: UsageWindow.weeklyId, label: "week", duration: 7 * day, usedPercent: 16.67, resetsAt: now.addingTimeInterval(6 * day)),
            ]),
            reading(.codex, plan: "plus", account: "fixture-codex-0002", [
                UsageWindow(id: UsageWindow.weeklyId, label: "week", duration: 7 * day, usedPercent: 10, resetsAt: now.addingTimeInterval(3.5 * day)),
            ]),
        ]
    }
}
