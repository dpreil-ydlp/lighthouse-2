import Foundation
import Testing
@testable import LighthouseCore

/// M1-07: test hooks are launch-argument only and all-or-nothing.
@Suite(.serialized) struct TestHooksTests {
    let realStore = URL(fileURLWithPath: "/Users/someone/Library/Application Support/Lighthouse/lighthouse.sqlite")
    let full = ["/Applications/Lighthouse.app/Contents/MacOS/Lighthouse",
                "-LighthouseTestStore", "/private/tmp/scratch/store.sqlite",
                "-LighthouseTestClaudeRoot", "/private/tmp/scratch/claude",
                "-LighthouseTestCodexHome", "/private/tmp/scratch/codex"]

    @Test func noArgumentLaunchIgnoresSavedHookKeys() {
        // Saved preferences with every hook key must not matter: parsing reads arguments only.
        let defaults = UserDefaults.standard
        let keys = ["LighthouseTestStore", "LighthouseTestClaudeRoot", "LighthouseTestCodexHome"]
        for key in keys { defaults.set("/private/tmp/scratch/\(key)", forKey: key) }
        defer { for key in keys { defaults.removeObject(forKey: key) } }
        #expect(defaults.string(forKey: "LighthouseTestStore") != nil)
        #expect(TestHooks.parse(arguments: ["/Applications/Lighthouse.app/Contents/MacOS/Lighthouse"], realStore: realStore) == .normal)
        #expect(TestHooks.parse(arguments: ["Lighthouse", "-NSDocumentRevisionsDebugMode", "YES"], realStore: realStore) == .normal)
    }

    @Test func partialConfigurationsAreRejected() {
        let flags = [TestHooks.storeFlag, TestHooks.claudeFlag, TestHooks.codexFlag]
        // Every non-empty strict subset of the three flags.
        for mask in 1..<7 {
            var arguments = ["Lighthouse"]
            for (bit, flag) in flags.enumerated() where mask & (1 << bit) != 0 {
                arguments += [flag, "/private/tmp/scratch/\(bit)"]
            }
            guard case .rejected = TestHooks.parse(arguments: arguments, realStore: realStore) else {
                Issue.record("accepted partial configuration \(arguments)")
                continue
            }
        }
        // A flag without a value, a repeated flag, a relative path, or the real store folder.
        let bad: [[String]] = [
            Array(full.dropLast()),
            full + ["-LighthouseTestStore", "/private/tmp/other.sqlite"],
            full.map { $0 == "/private/tmp/scratch/claude" ? "scratch/claude" : $0 },
            full.map { $0 == "/private/tmp/scratch/store.sqlite" ? realStore.path : $0 },
            full.map { $0 == "/private/tmp/scratch/store.sqlite" ? realStore.deletingLastPathComponent().appendingPathComponent("x.sqlite").path : $0 },
        ]
        for arguments in bad {
            guard case .rejected = TestHooks.parse(arguments: arguments, realStore: realStore) else {
                Issue.record("accepted \(arguments)")
                continue
            }
        }
    }

    @Test func fullScratchConfigurationWorks() async throws {
        #expect(TestHooks.parse(arguments: full, realStore: realStore)
                == .test(store: URL(fileURLWithPath: "/private/tmp/scratch/store.sqlite"),
                         claudeRoot: "/private/tmp/scratch/claude", codexHome: "/private/tmp/scratch/codex"))

        // End to end on fixtures: the parsed configuration drives an engine over scratch data only.
        let s = Scratch()
        s.installFixtures()
        let arguments = ["Lighthouse", "-LighthouseTestStore", s.path + "/store/lighthouse.sqlite",
                         "-LighthouseTestClaudeRoot", s.claudeRoot, "-LighthouseTestCodexHome", s.codexHome]
        guard case .test(let storeURL, let claude, let codex) = TestHooks.parse(arguments: arguments, realStore: realStore) else {
            Issue.record("full configuration rejected")
            return
        }
        let store = try Store(url: storeURL)
        let engine = Engine(collectors: [ClaudeCodeCollector(root: claude, store: store), CodexCollector(codexHome: codex, store: store)],
                            store: store, home: s.path)
        let snapshot = await engine.indexToCompletion()
        #expect(snapshot.projects.flatMap(\.threads).count == 4)
        #expect(store.url.path.hasPrefix(s.path))
    }

    /// Static guard: the app reads no hook key from UserDefaults.
    @Test func appDoesNotReadHookKeysFromDefaults() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/Lighthouse")
        for name in try FileManager.default.contentsOfDirectory(atPath: app.path) where name.hasSuffix(".swift") {
            let text = try String(contentsOf: app.appendingPathComponent(name), encoding: .utf8)
            #expect(!text.contains("forKey: \"LighthouseTest"), "\(name) reads a test hook from UserDefaults")
            #expect(!text.contains("string(forKey: \"LighthouseTest"), "\(name) reads a test hook from UserDefaults")
        }
        let model = try String(contentsOf: app.appendingPathComponent("AppModel.swift"), encoding: .utf8)
        #expect(model.contains("TestHooks.parse(arguments: CommandLine.arguments)"))
    }
}
