import Foundation
import Testing
@testable import LighthouseCore

/// M1-06: placement freezes on each real open, applies after close and reopen; warm-up is not an open.
@Suite struct PanelSessionTests {
    let now = Fixture.date("2026-10-29T12:00:00.000Z")

    func project(_ name: String, state: ThreadState, minutesAgo: Double) -> ProjectSummary {
        let thread = SessionThread(id: "codex:\(name)", owningApp: .codex, providerIdentities: [ProviderIdentity(provider: .codex, nativeId: name)],
                                   cwd: "/P/\(name)", state: state, sourceReadAt: now, lastActivityAt: now.addingTimeInterval(-minutesAgo * 60))
        let identity = ProjectIdentity(root: "/P/\(name)", name: name, kind: .git)
        return ShelfBuilder.summarize(threads: [thread], identities: [identity], now: now)[0]
    }

    func shelf(_ projects: [ProjectSummary]) -> Shelf { ShelfBuilder.build(projects: projects, prefs: ProjectPrefs(), now: now) }

    @Test func placementFrozenWhileOpenAppliesAfterReopen() {
        // At open: a is working (Active), b is quiet (Quiet).
        let before = shelf([project("a", state: .running, minutesAgo: 1), project("b", state: .idle, minutesAgo: 3000)])
        var session = PanelSession()
        session.show(live: before, warmup: false)
        #expect(session.isOpen)

        // While open, the statuses swap: a goes quiet, b starts working.
        let after = shelf([project("a", state: .idle, minutesAgo: 3000), project("b", state: .running, minutesAgo: 0)])
        let shown = session.displayed(after)
        #expect(shown.group(of: "/P/a") == .active)
        #expect(shown.group(of: "/P/b") == .quiet)
        #expect(shown[.active].first?.status == .quiet)   // row data is live
        // A second show event while already open does not re-freeze.
        session.show(live: after, warmup: false)
        #expect(session.displayed(after).group(of: "/P/a") == .active)

        // Close, then reopen: the new placement applies.
        session.hide()
        #expect(!session.isOpen)
        #expect(session.displayed(after) == after)
        session.show(live: after, warmup: false)
        #expect(session.displayed(after).group(of: "/P/b") == .active)
        #expect(session.displayed(after).group(of: "/P/a") == .quiet)
    }

    @Test func warmupShowIsNotAnOpen() {
        let before = shelf([project("a", state: .running, minutesAgo: 1)])
        var session = PanelSession()
        session.show(live: before, warmup: true)
        #expect(!session.isOpen)
        // Nothing is frozen: a status change after warm-up shows live placement.
        let after = shelf([project("a", state: .idle, minutesAgo: 3000)])
        #expect(session.displayed(after).group(of: "/P/a") == .quiet)
    }

    @Test func ownerActionAppliesWhileOpen() {
        let base = shelf([project("a", state: .idle, minutesAgo: 3000)])
        var session = PanelSession()
        session.show(live: base, warmup: false)
        let pinned = ShelfBuilder.build(projects: base.all, prefs: ProjectPrefs(pinned: ["/P/a"]), now: now)
        session.refreeze(live: pinned)
        #expect(session.displayed(pinned).group(of: "/P/a") == .pinned)
    }
}
