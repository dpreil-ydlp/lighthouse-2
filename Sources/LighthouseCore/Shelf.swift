import CoreGraphics
import Foundation

/// Derived project status (SPEC §5.3), first match wins. `paused` and `archived` are owner labels.
public enum ProjectStatus: String, Sendable, Hashable, Codable {
    case needsYou
    case working
    case recent
    case quiet
    case dormant

    var activeRank: Int {
        switch self {
        case .needsYou: 0
        case .working: 1
        case .recent: 2
        case .quiet: 3
        case .dormant: 4
        }
    }
}

public struct ProjectSummary: Sendable, Hashable, Identifiable {
    public var id: String { identity.root }
    public var identity: ProjectIdentity
    /// Threads in shelf order: running > waitingForOwner > idle > unknown > stopped, then newest first.
    public var threads: [SessionThread]
    public var status: ProjectStatus
    public var lastActivityAt: Date?
    /// Open attention reasons (SPEC §5.4), waiting first; derived from `attentionItems`.
    public var attention: [String]
    /// Open, unacknowledged attention incidents (M3: waiting for owner, silent subagent).
    public var attentionItems: [AttentionItem]

    public init(identity: ProjectIdentity, threads: [SessionThread], status: ProjectStatus, lastActivityAt: Date?, attention: [String] = [],
                attentionItems: [AttentionItem] = []) {
        self.identity = identity
        self.threads = threads
        self.status = status
        self.lastActivityAt = lastActivityAt
        self.attention = attention
        self.attentionItems = attentionItems
    }

    /// Owning-app chips (SPEC §6.2).
    public var owningApps: [OwningApp] {
        let present = Set(threads.map(\.owningApp))
        return OwningApp.allCases.filter(present.contains)
    }

    public var liveThreads: [SessionThread] { threads.filter { $0.state != .stopped } }
    public var stoppedThreads: [SessionThread] { threads.filter { $0.state == .stopped } }
    public var runningThreadCount: Int { threads.filter { $0.state == .running }.count }
    /// Open requests waiting for the owner (approval or input), threads and subagents together.
    public var waitingItems: [AttentionItem] { attentionItems.filter { $0.kind == .waitingForOwner } }

    /// Threads that wait for the owner (their own request or reply, or a waiting subagent), oldest
    /// wait first. Stopped threads count too: a finished run can still be waiting on the owner.
    public var waitingThreads: [SessionThread] {
        var seen = Set<String>()
        let ids = waitingItems.sorted { $0.enteredAt < $1.enteredAt }.map(\.threadId).filter { seen.insert($0).inserted }
        return ids.compactMap { id in threads.first { $0.id == id } }
    }

    /// Rows shown when the project is expanded: every waiting thread first, then live threads in
    /// shelf order, up to `limit` rows in all (more when more threads wait).
    public func expansionThreads(limit: Int) -> [SessionThread] {
        let waiting = waitingThreads
        let ids = Set(waiting.map(\.id))
        let rest = liveThreads.filter { !ids.contains($0.id) }
        return waiting + rest.prefix(max(0, limit - waiting.count))
    }
    public var mostRecentThread: SessionThread? { threads.max { $0.latestActivityAt < $1.latestActivityAt } }
}

/// Owner-set shelf preferences. Persisted in the store; pins keep manual order.
public struct ProjectPrefs: Sendable, Hashable, Codable {
    public var pinned: [String]
    public var paused: Set<String>
    public var archived: Set<String>

    public init(pinned: [String] = [], paused: Set<String> = [], archived: Set<String> = []) {
        self.pinned = pinned
        self.paused = paused
        self.archived = archived
    }
}

public enum ShelfGroup: String, Sendable, Hashable, CaseIterable {
    case pinned, active, recentlyCompleted, quiet, paused, archived, unassigned

    /// Groups shown expanded with no disclosure header.
    public var alwaysOpen: Bool { self == .pinned || self == .active || self == .recentlyCompleted }

    public var title: String {
        switch self {
        case .pinned: "Pinned"
        case .active: "Active"
        case .recentlyCompleted: "Recently completed"
        case .quiet: "Quiet"
        case .paused: "Paused"
        case .archived: "Archived"
        case .unassigned: "Unassigned"
        }
    }
}

public struct Shelf: Sendable, Hashable {
    public var groups: [ShelfGroup: [ProjectSummary]]

    public init(groups: [ShelfGroup: [ProjectSummary]] = [:]) { self.groups = groups }

    public static let empty = Shelf()

    public subscript(group: ShelfGroup) -> [ProjectSummary] {
        get { groups[group] ?? [] }
        set { groups[group] = newValue }
    }

    /// Every project in display order. Each project appears exactly once.
    public var all: [ProjectSummary] { ShelfGroup.allCases.flatMap { self[$0] } }
    public var isEmpty: Bool { all.isEmpty }

    public func group(of root: String) -> ShelfGroup? {
        ShelfGroup.allCases.first { self[$0].contains { $0.identity.root == root } }
    }
}

public enum Decay {
    public static let recentWindow: TimeInterval = 15 * 60
    public static let dormantAfter: TimeInterval = 7 * 24 * 60 * 60
    /// "Fresh evidence" for a running thread: activity within this window (the §5.4 stall threshold).
    public static let freshEvidence: TimeInterval = 30 * 60

    public static func status(threads: [SessionThread], hasAttention: Bool, now: Date) -> ProjectStatus {
        if hasAttention { return .needsYou }
        let working = threads.contains { thread in
            thread.state == .running && now.timeIntervalSince(thread.latestActivityAt) < freshEvidence
                && now.timeIntervalSince(thread.sourceReadAt) <= StateRules.sourceStaleAfter
        }
        if working { return .working }
        guard let last = threads.map(\.latestActivityAt).max() else { return .dormant }
        let age = now.timeIntervalSince(last)
        if age < recentWindow { return .recent }
        return age <= dormantAfter ? .quiet : .dormant
    }
}

/// Owner shelf options. A project that stopped within `recentlyCompletedWindow` shows in
/// "Recently completed" instead of Quiet, so work left overnight is still on the shelf next day.
public struct ShelfOptions: Sendable, Hashable {
    public static let defaultHours = 24
    /// Choices offered in Settings, in hours.
    public static let hourChoices = [4, 8, 12, 24, 48, 72, 168]

    public var recentlyCompletedWindow: TimeInterval

    public init(recentlyCompletedHours: Int = ShelfOptions.defaultHours) {
        recentlyCompletedWindow = TimeInterval(max(recentlyCompletedHours, 0)) * 3600
    }
}

public enum ShelfBuilder {
    public static let threadsShownExpanded = 3
    public static let pinsVisible = 3

    static func threadOrder(_ a: SessionThread, _ b: SessionThread) -> Bool {
        if a.state.shelfRank != b.state.shelfRank { return a.state.shelfRank < b.state.shelfRank }
        return a.latestActivityAt > b.latestActivityAt
    }

    /// Groups threads into project summaries. Attention items come from §5.4 rules on the threads;
    /// acknowledged incident identities are hidden. `attention` adds fixed reasons (tests).
    public static func summarize(threads: [SessionThread], identities: [ProjectIdentity], attention: [String: [String]] = [:],
                                 acknowledged: Set<String> = [], now: Date,
                                 observedSince: ObservedSince = AttentionRules.alwaysObserved) -> [ProjectSummary] {
        var grouped: [String: (ProjectIdentity, [SessionThread])] = [:]
        for (thread, identity) in zip(threads, identities) {
            grouped[identity.root, default: (identity, [])].1.append(thread)
        }
        return grouped.values.map { identity, threads in
            let items = threads.flatMap { AttentionRules.items(for: $0, now: now, observedSince: observedSince) }.filter { !acknowledged.contains($0.id) }
            let reasons = AttentionRules.reasons(items, now: now) + (attention[identity.root] ?? [])
            return ProjectSummary(
                identity: identity,
                threads: threads.sorted(by: threadOrder),
                status: Decay.status(threads: threads, hasAttention: !reasons.isEmpty, now: now),
                lastActivityAt: threads.map(\.latestActivityAt).max(),
                attention: reasons,
                attentionItems: items
            )
        }
    }

    /// Membership (SPEC §6.2 item 5): each project in exactly one group. Pinned wins over all groups;
    /// attention wins over Paused and Archived (shown in Active with a tag); then Archived, Paused,
    /// Unassigned, Active (needsYou, working, recent), Recently completed (quiet or dormant with
    /// activity inside the window), Quiet (the rest).
    public static func build(projects: [ProjectSummary], prefs: ProjectPrefs, options: ShelfOptions = ShelfOptions(),
                             now: Date) -> Shelf {
        var shelf = Shelf.empty
        let byRoot = Dictionary(projects.map { ($0.identity.root, $0) }, uniquingKeysWith: { a, _ in a })
        let pinned = prefs.pinned.compactMap { byRoot[$0] }
        shelf[.pinned] = pinned
        let pinnedSet = Set(pinned.map(\.identity.root))
        for project in projects where !pinnedSet.contains(project.identity.root) {
            shelf[placement(of: project, prefs: prefs, options: options, now: now)].append(project)
        }
        shelf[.active].sort(by: activeOrder)
        shelf[.recentlyCompleted].sort(by: newestFirst)
        for group in [ShelfGroup.quiet, .paused, .archived, .unassigned] { shelf[group].sort(by: alphabetical) }
        return shelf
    }

    static func placement(of project: ProjectSummary, prefs: ProjectPrefs, options: ShelfOptions,
                          now: Date) -> ShelfGroup {
        let root = project.identity.root
        if project.status == .needsYou { return .active }
        if prefs.archived.contains(root) { return .archived }
        if prefs.paused.contains(root) { return .paused }
        if project.identity.isUnassigned { return .unassigned }
        switch project.status {
        case .needsYou, .working, .recent: return .active
        case .quiet, .dormant:
            guard let last = project.lastActivityAt, now.timeIntervalSince(last) <= options.recentlyCompletedWindow else { return .quiet }
            return .recentlyCompleted
        }
    }

    /// The owner-label tag a project shows when attention lifted it out of Paused/Archived.
    public static func ownerTag(for project: ProjectSummary, prefs: ProjectPrefs) -> String? {
        if prefs.archived.contains(project.identity.root) { return "archived" }
        if prefs.paused.contains(project.identity.root) { return "paused" }
        return nil
    }

    /// needsYou, then working, then recent; each by last activity descending.
    static func activeOrder(_ a: ProjectSummary, _ b: ProjectSummary) -> Bool {
        if a.status.activeRank != b.status.activeRank { return a.status.activeRank < b.status.activeRank }
        let l = a.lastActivityAt ?? .distantPast, r = b.lastActivityAt ?? .distantPast
        if l != r { return l > r }
        return alphabetical(a, b)
    }

    static func newestFirst(_ a: ProjectSummary, _ b: ProjectSummary) -> Bool {
        let l = a.lastActivityAt ?? .distantPast, r = b.lastActivityAt ?? .distantPast
        return l != r ? l > r : alphabetical(a, b)
    }

    static func alphabetical(_ a: ProjectSummary, _ b: ProjectSummary) -> Bool {
        let order = a.identity.name.localizedCaseInsensitiveCompare(b.identity.name)
        return order == .orderedSame ? a.identity.root < b.identity.root : order == .orderedAscending
    }

    /// Freezes group placement and order while the panel is open (SPEC §6.2): rows keep the group
    /// and position they had at open while their data updates live. Removed projects drop out; new
    /// projects append to the group they would join. Each project still appears exactly once.
    public static func freeze(_ live: Shelf, to frozen: Shelf) -> Shelf {
        let byRoot = Dictionary(live.all.map { ($0.identity.root, $0) }, uniquingKeysWith: { a, _ in a })
        var placed = Set<String>()
        var result = Shelf.empty
        for group in ShelfGroup.allCases {
            result[group] = frozen[group].compactMap { old in
                guard let current = byRoot[old.identity.root], placed.insert(old.identity.root).inserted else { return nil }
                return current
            }
        }
        for group in ShelfGroup.allCases {
            for project in live[group] where placed.insert(project.identity.root).inserted {
                result[group].append(project)
            }
        }
        return result
    }

    /// Search across every group, including Quiet/Paused/Archived (SPEC §6.2 item 4).
    public static func search(_ query: String, in projects: [ProjectSummary]) -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var hits: [SearchHit] = []
        for project in projects {
            if project.identity.name.localizedCaseInsensitiveContains(q) {
                hits.append(SearchHit(project: project, thread: nil))
            }
            for thread in project.threads where thread.displayTitle.localizedCaseInsensitiveContains(q) {
                hits.append(SearchHit(project: project, thread: thread))
            }
        }
        return hits
    }
}

public struct SearchHit: Sendable, Hashable, Identifiable {
    public var id: String { project.id + "›" + (thread?.id ?? "") }
    public var project: ProjectSummary
    public var thread: SessionThread?

    public var breadcrumb: String {
        thread.map { "\(project.identity.name) › \($0.displayTitle)" } ?? project.identity.name
    }
}

/// Keyboard focus order for the panel (SPEC §9): one stop per visible row. Usage rows come first
/// (⏎ pushes the provider page). Collapsed groups
/// contribute their header; expanding a group or project adds its rows in place. When pins
/// overflow, a "More pins" stop follows the visible pins.
public enum FocusOrder {
    public enum Stop: Hashable, Sendable {
        case provider(Provider)
        case groupHeader(ShelfGroup)
        case project(String)
        case thread(project: String, thread: String)
        case showAll(project: String)
        case morePins
    }

    public static func stops(shelf: Shelf, expandedGroups: Set<ShelfGroup>, expandedProject: String?, pinsExpanded: Bool,
                             providers: [Provider] = []) -> [Stop] {
        var stops: [Stop] = providers.map(Stop.provider)
        for group in ShelfGroup.allCases {
            let rows = shelf[group]
            guard !rows.isEmpty else { continue }
            stops.append(.groupHeader(group))
            let open = group.alwaysOpen || expandedGroups.contains(group)
            guard open else { continue }
            let collapsedPins = group == .pinned && !pinsExpanded && rows.count > ShelfBuilder.pinsVisible
            let visible = collapsedPins ? Array(rows.prefix(ShelfBuilder.pinsVisible)) : rows
            for project in visible {
                stops.append(.project(project.identity.root))
                guard project.identity.root == expandedProject else { continue }
                // Same rows as the expanded view: waiting threads first (owner 2026-11-03).
                let shown = project.expansionThreads(limit: ShelfBuilder.threadsShownExpanded)
                for thread in shown {
                    stops.append(.thread(project: project.identity.root, thread: thread.id))
                }
                if project.threads.count > shown.count {
                    stops.append(.showAll(project: project.identity.root))
                }
            }
            if collapsedPins { stops.append(.morePins) }
        }
        return stops
    }
}

/// Expansion state the keyboard and mouse both change. The app holds one; actions here keep the
/// keyboard path identical to the visible controls (SPEC §9, §6.2 pin overflow).
public struct ShelfNavigation: Sendable, Hashable {
    public var expandedGroups: Set<ShelfGroup> = []
    public var expandedProject: String?
    public var pinsExpanded = false
    public var focused: FocusOrder.Stop?
    /// Usage rows shown above the shelf, in display order.
    public var providers: [Provider] = []

    public init() {}

    public func stops(in shelf: Shelf) -> [FocusOrder.Stop] {
        FocusOrder.stops(shelf: shelf, expandedGroups: expandedGroups, expandedProject: expandedProject, pinsExpanded: pinsExpanded,
                         providers: providers)
    }

    public mutating func move(_ delta: Int, in shelf: Shelf) {
        let stops = stops(in: shelf)
        guard !stops.isEmpty else { return }
        let index = focused.flatMap { stops.firstIndex(of: $0) } ?? (delta > 0 ? -1 : stops.count)
        focused = stops[min(max(index + delta, 0), stops.count - 1)]
    }

    /// Reveals the hidden pins; focus moves to the first pin that was hidden.
    public mutating func showMorePins(in shelf: Shelf) {
        pinsExpanded = true
        let pins = shelf[.pinned]
        if pins.count > ShelfBuilder.pinsVisible { focused = .project(pins[ShelfBuilder.pinsVisible].identity.root) }
    }

    /// What ⏎ or → does on a stop that changes expansion. Returns the project page to push, if any.
    public enum Outcome: Equatable, Sendable {
        case none
        case push(String)
        case pushProvider(Provider)
        case openThread(project: String, thread: String)
    }

    public mutating func activate(in shelf: Shelf) -> Outcome {
        switch focused {
        case .provider(let provider)?:
            return .pushProvider(provider)
        case .groupHeader(let group)?:
            if expandedGroups.remove(group) == nil { expandedGroups.insert(group) }
            return .none
        case .project(let root)?, .showAll(let root)?:
            return .push(root)
        case .thread(let root, let id)?:
            return .openThread(project: root, thread: id)
        case .morePins?:
            showMorePins(in: shelf)
            return .none
        case nil:
            return .none
        }
    }

    /// → : expand a group or project, push when already expanded.
    public mutating func expand(in shelf: Shelf) -> Outcome {
        switch focused {
        case .provider(let provider)?:
            return .pushProvider(provider)
        case .groupHeader(let group)?:
            expandedGroups.insert(group)
            return .none
        case .project(let root)?:
            if expandedProject == root { return .push(root) }
            expandedProject = root
            return .none
        case .showAll(let root)?, .thread(let root, _)?:
            return .push(root)
        case .morePins?:
            showMorePins(in: shelf)
            return .none
        case nil:
            return .none
        }
    }

    /// ← : collapse the focused group or project.
    public mutating func collapse() {
        switch focused {
        case .groupHeader(let group)?: expandedGroups.remove(group)
        case .project(let root)?: if expandedProject == root { expandedProject = nil }
        case .thread(let root, _)?, .showAll(let root)?:
            expandedProject = nil
            focused = .project(root)
        case .provider?, .morePins?, nil: break
        }
    }

    /// The project a ⌘O / ⌘P shortcut applies to: the focused project, or the project of the
    /// focused thread or "Show all" row.
    public var focusedProject: String? {
        switch focused {
        case .project(let root)?, .showAll(let root)?, .thread(let root, _)?: root
        case .provider?, .groupHeader?, .morePins?, nil: nil
        }
    }
}

/// Keyboard focus on a project page (SPEC §6.4, §9): one stop per visible thread, then the
/// "n earlier threads" toggle, then the earlier threads when shown.
public struct PageNavigation: Sendable, Hashable {
    public enum Stop: Hashable, Sendable {
        case thread(String)
        case earlier
    }

    public var focused: Stop?
    public var showEarlier = false

    public init() {}

    public static func stops(_ project: ProjectSummary, showEarlier: Bool, now: Date) -> [Stop] {
        let (current, earlier) = ThreadDisplay.split(project.threads, now: now)
        var stops = current.map { Stop.thread($0.id) }
        if !earlier.isEmpty {
            stops.append(.earlier)
            if showEarlier { stops += earlier.map { Stop.thread($0.id) } }
        }
        return stops
    }

    public mutating func move(_ delta: Int, in project: ProjectSummary, now: Date) {
        let stops = Self.stops(project, showEarlier: showEarlier, now: now)
        guard !stops.isEmpty else { return }
        let index = focused.flatMap { stops.firstIndex(of: $0) } ?? (delta > 0 ? -1 : stops.count)
        focused = stops[min(max(index + delta, 0), stops.count - 1)]
    }

    public var focusedThread: String? {
        if case .thread(let id)? = focused { return id }
        return nil
    }
}

/// SPEC 2.4 §6.4 display rule: threads that are not running or waiting and have had no activity
/// for 48 h fold into "n earlier threads". Display only; it never changes a thread's state.
public enum ThreadDisplay {
    public static let earlierAfter: TimeInterval = 48 * 60 * 60

    public static func split(_ threads: [SessionThread], now: Date) -> (current: [SessionThread], earlier: [SessionThread]) {
        var current: [SessionThread] = []
        var earlier: [SessionThread] = []
        for thread in threads {
            let active = thread.state == .running || thread.state == .waitingForOwner
            if !active && now.timeIntervalSince(thread.latestActivityAt) >= earlierAfter {
                earlier.append(thread)
            } else {
                current.append(thread)
            }
        }
        return (current, earlier)
    }
}

/// Whether the panel is open, and the shelf placement frozen while it is (SPEC §6.2: group
/// placement and order freeze while open; status text and ages update live; new placement applies
/// on the next open). The invisible warm-up show at launch is not an open.
public struct PanelSession: Sendable, Hashable {
    public private(set) var isOpen = false
    private var frozen: Shelf?

    public init() {}

    /// A show of the panel window. Ignored when `warmup` is true or the panel is already open.
    public mutating func show(live: Shelf, warmup: Bool) {
        guard !warmup, !isOpen else { return }
        isOpen = true
        frozen = live
    }

    public mutating func hide() {
        isOpen = false
        frozen = nil
    }

    /// The user's own action (pin, pause, archive) applies at once, even while open.
    public mutating func refreeze(live: Shelf) {
        if isOpen { frozen = live }
    }

    /// The shelf to display: frozen placement with live row data while open, live otherwise.
    public func displayed(_ live: Shelf) -> Shelf {
        guard let frozen else { return live }
        return ShelfBuilder.freeze(live, to: frozen)
    }
}

/// The panel's pages (SPEC §6.2–6.4).
public enum PanelRoute: Hashable, Sendable {
    case home
    case project(String)
    case provider(Provider)
}

/// Pushed pages and provider-page keyboard focus (SPEC §6.3, §9). Navigation depth stays ≤ 2: a
/// project opened from a provider page returns there, with the same row focused.
public struct PanelRoutes: Sendable, Hashable {
    public var route: PanelRoute = .home {
        didSet {
            if case .project = route {} else { projectReturn = nil }
            // A provider page reached from home starts unfocused; Back from its project keeps the row.
            if case .provider = route, case .project = oldValue {} else if route != oldValue, case .provider = route { providerFocus = nil }
        }
    }
    public private(set) var projectReturn: PanelRoute?
    /// Focused row in the provider page's project list.
    public var providerFocus: Int?

    public init() {}

    public mutating func openProject(_ root: String, from provider: Provider) {
        route = .project(root)
        projectReturn = .provider(provider)
    }

    /// Back: a project opened from a provider page returns there; anything else returns home.
    public mutating func pop() {
        route = projectReturn ?? .home
    }

    /// ↑/↓ on the provider page over `count` project rows.
    public mutating func moveProviderFocus(_ delta: Int, count: Int) {
        guard case .provider = route, count > 0 else { return }
        let index = providerFocus ?? (delta > 0 ? -1 : count)
        providerFocus = min(max(index + delta, 0), count - 1)
    }

    /// ⏎ or → on the provider page: opens the focused project row (`roots` in display order).
    @discardableResult
    public mutating func activateProviderFocus(roots: [String]) -> Bool {
        guard case .provider(let provider) = route, let index = providerFocus, roots.indices.contains(index) else { return false }
        openProject(roots[index], from: provider)
        return true
    }
}

/// Panel frame (SPEC §6: height grows to content, max = min(720, screen − 80); M4-R09). The panel
/// stays anchored under the status item: a height change moves the bottom edge, never the top.
public enum PanelFrame {
    /// The frame for `contentHeight` (window coordinates: origin bottom-left, y up). Returns nil when
    /// the frame already fits within half a point.
    public static func fitted(_ frame: CGRect, contentHeight: CGFloat, maxHeight: CGFloat) -> CGRect? {
        guard contentHeight > 0 else { return nil }
        let height = min(contentHeight.rounded(.up), maxHeight)
        guard abs(frame.height - height) > 0.5 else { return nil }
        return CGRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
    }

    /// The tallest the page's scroll area may be so the whole page stays within `maxHeight`: the
    /// maximum minus everything else on the page (header, usage block, strip, footer), measured as
    /// `contentHeight − scrollHeight`. Before both are measured, `maxHeight − 160` as before.
    public static func scrollCap(maxHeight: CGFloat, contentHeight: CGFloat, scrollHeight: CGFloat, minimum: CGFloat = 120) -> CGFloat {
        guard contentHeight > 0, scrollHeight > 0, contentHeight >= scrollHeight else { return maxHeight - 160 }
        return max(minimum, maxHeight - (contentHeight - scrollHeight))
    }
}

/// The main-page "what's happening" line for an active project (M10): the AI summary of the thread
/// that matters most, else that thread's title. Quiet projects get none.
public struct ProjectHeadline: Sendable, Hashable {
    public var threadId: String
    public var text: String
    /// True when `text` is an AI summary rather than the thread title.
    public var isSummary: Bool

    /// Thread choice: a thread waiting for the owner when the project needs them, else the first
    /// thread in shelf order (running, then waiting, then idle; most recent first).
    /// `recentlyCompleted`: the project sits in "Recently completed", so it gets a headline too.
    public static func make(for project: ProjectSummary, recentlyCompleted: Bool = false,
                            summary: (SessionThread) -> ThreadSummary?) -> ProjectHeadline? {
        guard recentlyCompleted || [.needsYou, .working, .recent].contains(project.status) else { return nil }
        let waiting = project.status == .needsYou
            ? project.threads.first { $0.state == .waitingForOwner } ?? project.threads.first { $0.asksOwnerAt != nil } : nil
        guard let thread = waiting ?? project.threads.first else { return nil }
        let names = [project.identity.name, thread.displayTitle]
        if let s = summary(thread), !s.line1.isEmpty {
            return ProjectHeadline(threadId: thread.id, text: dropLeading(names, from: s.line1), isSummary: true)
        }
        return ProjectHeadline(threadId: thread.id, text: dropLeading([project.identity.name], from: thread.displayTitle), isSummary: false)
    }

    /// "Groove migration: 3 of 4 invites sent" under the row named "Groove migration" reads
    /// "3 of 4 invites sent". Only a name followed by ":" or a dash is dropped.
    static func dropLeading(_ names: [String], from text: String) -> String {
        for name in names where !name.isEmpty {
            guard let match = text.range(of: name, options: [.anchored, .caseInsensitive]) else { continue }
            let rest = text[match.upperBound...].drop { $0 == " " }
            guard let mark = rest.first, ":-–—|".contains(mark) else { continue }
            let remainder = rest.dropFirst().trimmingCharacters(in: .whitespaces)
            if !remainder.isEmpty { return remainder }
        }
        return text
    }
}
