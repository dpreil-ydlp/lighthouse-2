import Foundation
import Testing
@testable import LighthouseCore

@Suite struct OpenRouterTests {
    let now = Fixture.date("2026-10-29T12:00:00.000Z")

    func thread(_ app: OwningApp, _ provider: Provider, _ id: String, minutesAgo: Double = 0) -> SessionThread {
        SessionThread(id: "\(provider.rawValue):\(id)", owningApp: app, providerIdentities: [ProviderIdentity(provider: provider, nativeId: id)],
                      cwd: "/P/x", state: .idle, sourceReadAt: now, lastActivityAt: now.addingTimeInterval(-minutesAgo * 60))
    }

    @Test func recordedCapabilitiesAreAppOnly() {
        let router = OpenRouter()
        let codex = router.target(for: thread(.codex, .codex, Fixture.codexParent))
        #expect(codex == .app(.chatGPT, sessionId: Fixture.codexParent))
        #expect(codex.label == "Open ChatGPT app")
        #expect(!codex.isExactThread)
        #expect(codex.sessionId == Fixture.codexParent)

        let claude = router.target(for: thread(.claudeCode, .claude, Fixture.claudeSession))
        #expect(claude == .app(.claude, sessionId: Fixture.claudeSession))
        #expect(claude.label == "Open Claude app")
    }

    @Test func owningAppDecidesNotProvider() {
        // A Codex session written by T3 Code with no T3 mapping opens T3 Code, app only (no T3 IDs).
        let t = router(.exactThread).target(for: thread(.t3, .codex, Fixture.codexT3))
        #expect(t == .app(.t3Code, sessionId: Fixture.codexT3))
        #expect(t.label == "Open T3 Code app")
    }

    func router(_ codex: RoutingCapability) -> OpenRouter {
        OpenRouter(capabilities: RoutingCapabilities(t3: .exactThread, codex: codex, claudeCode: .exactThread))
    }

    @Test func exactThreadCapabilityBuildsLinks() {
        let codex = router(.exactThread).target(for: thread(.codex, .codex, Fixture.codexParent))
        #expect(codex == .link(URL(string: "codex://threads/\(Fixture.codexParent)")!, app: .chatGPT))
        #expect(codex.label == "Open in ChatGPT ↗")

        var t3 = thread(.t3, .codex, "native")
        t3.t3EnvironmentId = "env 1"
        t3.t3ThreadId = "thread/2"
        #expect(router(.exactThread).target(for: t3) == .link(URL(string: "t3code://threads/env%201/thread%2F2")!, app: .t3Code))

        // Claude has no passive link format: even "exactThread" falls back to app only.
        let claude = router(.exactThread).target(for: thread(.claudeCode, .claude, Fixture.claudeSession))
        #expect(claude == .app(.claude, sessionId: Fixture.claudeSession))
    }

    @Test func overrideChangesOnlyTheApp() {
        let r = OpenRouter(overrides: [.claudeCode: OpenOverride(appPath: "/Applications/Visual Studio Code.app", appName: "Visual Studio Code")])
        let action = r.target(for: thread(.claudeCode, .claude, Fixture.claudeSession))
        #expect(action == .appWithFolder(appPath: "/Applications/Visual Studio Code.app", appName: "Visual Studio Code", folder: "/P/x", sessionId: Fixture.claudeSession))
        #expect(action.label == "Open Visual Studio Code app")
    }

    @Test func projectTargets() {
        let threads = [thread(.claudeCode, .claude, "c", minutesAgo: 1), thread(.codex, .codex, "x", minutesAgo: 30), thread(.codex, .codex, "y", minutesAgo: 40)]
        let identity = ProjectIdentity(root: "/P/x", name: "x", kind: .git)
        let project = ShelfBuilder.summarize(threads: threads, identities: Array(repeating: identity, count: 3), now: now)[0]
        let router = OpenRouter()
        let primary = router.primaryTarget(for: project)
        #expect(primary.thread?.sessionId == "c")
        #expect(primary.action.appName == "Claude")
        #expect(router.allTargets(for: project).map(\.action.appName) == ["Claude", "ChatGPT"])

        let empty = ProjectSummary(identity: identity, threads: [], status: .dormant, lastActivityAt: nil)
        #expect(router.primaryTarget(for: empty).action == .reveal(path: "/P/x"))
    }

    /// SPEC §7 recorded capabilities for this build: T3 proven (M3 C3), Codex and Claude app-only.
    @Test func recordedCapabilitiesMatchTheReceipts() {
        #expect(RoutingCapabilities.recorded == RoutingCapabilities(t3: .exactThread, codex: .appOnly, claudeCode: .appOnly))
        var t3 = thread(.t3, .codex, "native")
        t3.t3EnvironmentId = "aaaaaaaa-0000-4000-8000-000000000004"
        t3.t3ThreadId = "mcp:aaaaaaaa-0000-4000-8000-000000000005"
        let action = OpenRouter().target(for: t3)
        #expect(action == .link(URL(string: "t3code://threads/aaaaaaaa-0000-4000-8000-000000000004/mcp%3Aaaaaaaaa-0000-4000-8000-000000000005")!, app: .t3Code))
        #expect(action.label == "Open in T3 Code ↗")
        // Without T3 IDs (a T3 Code-originated Codex session with no mapping) it stays app-only.
        #expect(OpenRouter().target(for: thread(.t3, .codex, Fixture.codexT3)) == .app(.t3Code, sessionId: Fixture.codexT3))
    }

    @Test func noForbiddenLinkIsEverBuilt() {
        let caps = [RoutingCapabilities.recorded, RoutingCapabilities(t3: .exactThread, codex: .exactThread, claudeCode: .exactThread)]
        for cap in caps {
            let r = OpenRouter(capabilities: cap)
            for app in OwningApp.allCases {
                for provider in Provider.allCases {
                    var t = thread(app, provider, Fixture.claudeSession)
                    t.t3EnvironmentId = "e"; t.t3ThreadId = "t"
                    if case .link(let url, _) = r.target(for: t) {
                        for prefix in OpenRouter.forbiddenLinkPrefixes { #expect(!url.absoluteString.hasPrefix(prefix)) }
                        #expect(url.scheme != "claude")
                    }
                }
            }
        }
    }
}
