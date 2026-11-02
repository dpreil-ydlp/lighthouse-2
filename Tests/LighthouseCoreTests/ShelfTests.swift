import Foundation
import Testing
@testable import LighthouseCore

@Suite struct ShelfTests {
    let now = Fixture.date("2026-10-29T12:00:00.000Z")

    func thread(_ id: String, state: ThreadState, minutesAgo: Double, app: OwningApp = .codex, title: String? = nil) -> SessionThread {
        let at = now.addingTimeInterval(-minutesAgo * 60)
        return SessionThread(id: "codex:\(id)", owningApp: app, providerIdentities: [ProviderIdentity(provider: .codex, nativeId: id)],
                             title: title ?? "Thread \(id)", cwd: "/x", state: state, sourceReadAt: now, lastActivityAt: at)
    }

    func project(_ name: String, _ threads: [SessionThread], attention: [String] = [], unassigned: Bool = false) -> ProjectSummary {
        let identity = unassigned ? ProjectIdentity(root: "unassigned:/tmp/\(name)", name: name, kind: .unassigned)
            : ProjectIdentity(root: "/P/\(name)", name: name, kind: .git)
        return ShelfBuilder.summarize(threads: threads, identities: Array(repeating: identity, count: threads.count),
                                      attention: attention.isEmpty ? [:] : [identity.root: attention], now: now)[0]
    }

    @Test func decayStatuses() {
        #expect(project("a", [thread("1", state: .running, minutesAgo: 2)]).status == .working)
        #expect(project("b", [thread("2", state: .idle, minutesAgo: 5)]).status == .recent)
        #expect(project("c", [thread("3", state: .idle, minutesAgo: 60)]).status == .quiet)
        #expect(project("d", [thread("4", state: .stopped, minutesAgo: 8 * 24 * 60)]).status == .dormant)
        // Running with stale evidence is not "working".
        #expect(project("e", [thread("5", state: .running, minutesAgo: 45)]).status == .quiet)
        // Unknown never counts as running.
        #expect(project("f", [thread("6", state: .unknown, minutesAgo: 1)]).status == .recent)
        #expect(project("g", [thread("7", state: .idle, minutesAgo: 60)], attention: ["Approval requested"]).status == .needsYou)
    }

    @Test func membershipRules() {
        let pinnedQuiet = project("pinned", [thread("1", state: .idle, minutesAgo: 600)])
        let pausedWithAttention = project("paused", [thread("2", state: .idle, minutesAgo: 600)], attention: ["Approval requested"])
        let archived = project("archived", [thread("3", state: .idle, minutesAgo: 600)])
        let unassigned = project("loose", [thread("4", state: .running, minutesAgo: 1)], unassigned: true)
        let recent = project("recent", [thread("5", state: .idle, minutesAgo: 3)])
        let working = project("working", [thread("6", state: .running, minutesAgo: 1)])
        let prefs = ProjectPrefs(pinned: [pinnedQuiet.id], paused: [pausedWithAttention.id], archived: [archived.id, pinnedQuiet.id])
        let shelf = ShelfBuilder.build(projects: [pinnedQuiet, pausedWithAttention, archived, unassigned, recent, working], prefs: prefs, now: now)
        #expect(shelf[.pinned].map(\.identity.name) == ["pinned"])
        #expect(shelf[.active].map(\.identity.name) == ["paused", "working", "recent"])
        #expect(ShelfBuilder.ownerTag(for: pausedWithAttention, prefs: prefs) == "paused")
        #expect(shelf[.archived].map(\.identity.name) == ["archived"])
        #expect(shelf[.unassigned].map(\.identity.name) == ["loose"])
        #expect(shelf[.paused].isEmpty)
    }

    @Test func threadOrderInExpansion() {
        let p = project("a", [thread("i", state: .idle, minutesAgo: 1), thread("u", state: .unknown, minutesAgo: 0),
                               thread("s", state: .stopped, minutesAgo: 0), thread("r", state: .running, minutesAgo: 9),
                               thread("w", state: .waitingForOwner, minutesAgo: 20)])
        #expect(p.threads.map(\.sessionId) == ["r", "w", "i", "u", "s"])
        #expect(p.stoppedThreads.count == 1)
    }

    /// SPEC §11 M1 (6): 15+ projects, 4 pins, one project with 5 live threads.
    @Test func largeShelfEachProjectOnceAndReachable() {
        var projects: [ProjectSummary] = []
        for i in 0..<16 {
            let threads = i == 0
                ? (0..<5).map { thread("busy-\($0)", state: .running, minutesAgo: Double($0)) }
                : [thread("p\(i)", state: i % 3 == 0 ? .running : .idle, minutesAgo: Double(i * 97 % 2000))]
            projects.append(project("Project \(i)", threads))
        }
        projects.append(project("Loose", [thread("loose", state: .idle, minutesAgo: 30)], unassigned: true))
        let pins = ["/P/Project 3", "/P/Project 0", "/P/Project 9", "/P/Project 12"]
        let prefs = ProjectPrefs(pinned: pins, paused: ["/P/Project 5"], archived: ["/P/Project 7"])
        let shelf = ShelfBuilder.build(projects: projects, prefs: prefs, now: now)

        let roots = shelf.all.map(\.identity.root)
        #expect(roots.count == projects.count)
        #expect(Set(roots).count == projects.count)
        #expect(shelf[.pinned].map(\.identity.root) == pins)

        // Keyboard from the real initial state (M1-05): everything collapsed, pins collapsed.
        // Only ↓ and ⏎ are used: ⏎ on a collapsed group header expands it, ⏎ on "More pins"
        // reveals the hidden pins. Every project must become a focus stop.
        var nav = ShelfNavigation()
        #expect(!nav.pinsExpanded)
        let initial = nav.stops(in: shelf)
        #expect(initial.contains(.morePins))
        #expect(!initial.contains(.project(pins[3])))
        var reached = Set<String>()
        for _ in 0..<400 {
            nav.move(1, in: shelf)
            switch nav.focused {
            case .project(let root)?: reached.insert(root)
            case .morePins?, .groupHeader?:
                let before = nav.stops(in: shelf).count
                _ = nav.activate(in: shelf)
                // Re-collapse is avoided: only activate a header while it adds rows.
                if nav.stops(in: shelf).count < before { _ = nav.activate(in: shelf) }
                if case .project(let root)? = nav.focused { reached.insert(root) }
            default: break
            }
        }
        #expect(nav.pinsExpanded)
        #expect(reached == Set(roots))

        // Expanding the busy project shows three threads plus "Show all n threads".
        nav.expandedProject = "/P/Project 0"
        let stops = nav.stops(in: shelf)
        let busyThreads = stops.filter { if case .thread(project: "/P/Project 0", _) = $0 { return true }; return false }
        #expect(busyThreads.count == 3)
        #expect(stops.contains(.showAll(project: "/P/Project 0")))

        // Search reaches every project and every thread title in every group.
        for project in projects {
            #expect(ShelfBuilder.search(project.identity.name, in: shelf.all).contains { $0.project.id == project.id && $0.thread == nil })
            for t in project.threads {
                #expect(ShelfBuilder.search(t.displayTitle, in: shelf.all).contains { $0.thread?.id == t.id })
            }
        }
    }

    @Test func freezeKeepsPlacementWhileDataUpdates() {
        let a = project("a", [thread("1", state: .running, minutesAgo: 1)])
        let b = project("b", [thread("2", state: .idle, minutesAgo: 3000)])
        let frozen = ShelfBuilder.build(projects: [a, b], prefs: ProjectPrefs(), now: now)
        #expect(frozen.group(of: a.id) == .active)
        // Later: a went quiet, b became active, c is new.
        let a2 = project("a", [thread("1", state: .idle, minutesAgo: 3000)])
        let b2 = project("b", [thread("2", state: .running, minutesAgo: 0)])
        let c = project("c", [thread("3", state: .running, minutesAgo: 0)])
        let live = ShelfBuilder.build(projects: [a2, b2, c], prefs: ProjectPrefs(), now: now)
        let shown = ShelfBuilder.freeze(live, to: frozen)
        #expect(shown.group(of: a.id) == .active)
        #expect(shown.group(of: b.id) == .quiet)
        #expect(shown[.active].first?.status == .quiet) // data updated in place
        #expect(shown.group(of: c.id) == .active)
        #expect(shown.all.count == 3)
    }

    /// Work left overnight stays on the shelf in "Recently completed"
    /// for the owner's window (default 24 h), then moves to Quiet.
    @Test func recentlyCompletedHoldsStoppedWorkForTheWindow() {
        let lastNight = project("lastNight", [thread("1", state: .idle, minutesAgo: 14 * 60)])
        let edge = project("edge", [thread("2", state: .stopped, minutesAgo: 24 * 60)])
        let old = project("old", [thread("3", state: .idle, minutesAgo: 25 * 60)])
        let earlier = project("earlier", [thread("4", state: .idle, minutesAgo: 60)])
        let recent = project("recent", [thread("5", state: .idle, minutesAgo: 5)])
        let working = project("working", [thread("6", state: .running, minutesAgo: 1)])
        let all = [old, lastNight, edge, earlier, recent, working]

        let shelf = ShelfBuilder.build(projects: all, prefs: ProjectPrefs(), now: now)
        #expect(shelf[.active].map(\.identity.name) == ["working", "recent"])
        #expect(shelf[.recentlyCompleted].map(\.identity.name) == ["earlier", "lastNight", "edge"]) // newest first
        #expect(shelf[.quiet].map(\.identity.name) == ["old"])
        #expect(Set(shelf.all.map(\.id)).count == all.count)

        // A shorter window moves last night's work to Quiet; a longer one keeps "old".
        let short = ShelfBuilder.build(projects: all, prefs: ProjectPrefs(), options: ShelfOptions(recentlyCompletedHours: 8), now: now)
        #expect(short[.recentlyCompleted].map(\.identity.name) == ["earlier"])
        #expect(short[.quiet].map(\.identity.name) == ["edge", "lastNight", "old"])
        let long = ShelfBuilder.build(projects: all, prefs: ProjectPrefs(), options: ShelfOptions(recentlyCompletedHours: 48), now: now)
        #expect(long[.recentlyCompleted].map(\.identity.name) == ["earlier", "lastNight", "edge", "old"])
        #expect(long[.quiet].isEmpty)

        // Owner labels and pins still win; Recently completed is open with no header click.
        let labeled = ShelfBuilder.build(projects: all, prefs: ProjectPrefs(pinned: [lastNight.id], paused: [edge.id]), now: now)
        #expect(labeled[.recentlyCompleted].map(\.identity.name) == ["earlier"])
        #expect(labeled[.paused].map(\.identity.name) == ["edge"])
        #expect(ShelfGroup.recentlyCompleted.alwaysOpen && !ShelfGroup.quiet.alwaysOpen)
        let stops = ShelfNavigation().stops(in: shelf)
        #expect(stops.contains(.project(lastNight.id)))
        #expect(!stops.contains(.project(old.id)))

        // A recently completed project gets the main-page headline; Quiet does not.
        #expect(ProjectHeadline.make(for: lastNight, recentlyCompleted: true) { _ in nil }?.text == "Thread 1")
        #expect(ProjectHeadline.make(for: old) { _ in nil } == nil)
    }

    @Test func shelfSettingsDefaultAndRoundTrip() {
        let defaults = AppSettings()
        #expect(defaults.recentlyCompletedHours == 24)
        #expect(!defaults.showQuiet)
        var changed = defaults
        changed.recentlyCompletedHours = 72
        changed.showQuiet = true
        #expect(AppSettings(values: changed.values) == changed)
        #expect(AppSettings(values: [:]) == defaults)
        #expect(changed.shelfOptions.recentlyCompletedWindow == 72 * 3600)
    }
}
