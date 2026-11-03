import AppKit
import LighthouseCore
import Observation
import os

let log = Logger(subsystem: "com.lighthouse.v2", category: "app")

typealias Route = PanelRoute

/// UI state over the engine snapshot. Holds metadata only.
@MainActor
@Observable
final class AppModel {
    private(set) var snapshot = Snapshot.empty
    private(set) var prefs = ProjectPrefs()
    private(set) var overrides: [OwningApp: OpenOverride] = [:]
    private(set) var bindings: [ProjectBinding] = []
    private(set) var storeError: String?
    private(set) var liveShelf = Shelf.empty
    /// Open state and the placement frozen while open (SPEC §6.2), driven by `PanelVisibility`.
    private(set) var session = PanelSession()

    /// Pages, Back target and provider-page focus (`PanelRoutes`, LighthouseCore).
    private(set) var routes = PanelRoutes()
    var route: Route {
        get { routes.route }
        set { changeRoutes { $0.route = newValue } }
    }

    private func changeRoutes(_ change: (inout PanelRoutes) -> Void) {
        let old = routes.route
        change(&routes)
        if routes.route != old {
            page = PageNavigation()
            log.notice("route \(self.routeName, privacy: .public)")
        }
    }
    /// Keyboard focus on the project page (SPEC §9).
    var page = PageNavigation()
    /// Attention strip filter (SPEC §6.2 item 3): a filter, not an inbox.
    var attentionFilter: AttentionBucket?
    /// Focused search result for ↑/↓ and ⏎ while searching.
    var searchFocus: Int?
    /// Where Back goes from a project page pushed from a provider page (SPEC §6.3; depth ≤ 2).
    var projectReturn: Route? { routes.projectReturn }
    var searchText = ""
    var searchVisible = false
    /// Expansion and focus, shared by keyboard and mouse (`ShelfNavigation`, LighthouseCore).
    var nav = ShelfNavigation()
    var expandedProject: String? {
        get { nav.expandedProject }
        set { nav.expandedProject = newValue }
    }
    var expandedThreads: Set<String> = []
    var expandedGroups: Set<ShelfGroup> {
        get { nav.expandedGroups }
        set { nav.expandedGroups = newValue }
    }
    var pinsExpanded: Bool {
        get { nav.pinsExpanded }
        set { nav.pinsExpanded = newValue }
    }
    var focused: FocusOrder.Stop? {
        get { nav.focused }
        set { nav.focused = newValue }
    }
    var toast: String?
    /// Height of the current page's scroll area, and its cap (M4-R09).
    var scrollHeight: CGFloat = 0
    var scrollCap: CGFloat {
        PanelFrame.scrollCap(maxHeight: Metrics.maxHeight, contentHeight: panelContentHeight, scrollHeight: scrollHeight)
    }
    /// The panel page's measured height (M4-R09); the window follows it while the panel is open.
    var panelContentHeight: CGFloat = 0 {
        didSet {
            guard panelContentHeight != oldValue, session.isOpen else { return }
            let height = panelContentHeight
            DispatchQueue.main.async { PanelControl.fit(contentHeight: height) }
        }
    }
    var now = Date()

    private let store: Store?
    /// Held for the life of the app: one writer per store (M9 F3).
    private let storeLock: StoreLock
    private let engine: Engine
    private var watcher: DirectoryWatcher?
    private var visibility: PanelVisibility?
    private let waker = Waker()
    private let touched = TouchedPaths()
    private var toastTask: Task<Void, Never>?

    // Usage (SPEC §5.5, §6.1–6.3). Readings live in memory only; tokens never leave `UsageMonitor`.
    private(set) var usageSettings = UsageSettings()
    private(set) var usage: [ProviderUsage] = []
    private(set) var glyph = UsageGlyphState(readings: [], now: Date())
    private let usageMonitor = UsageMonitor.live()
    private let usageWaker = Waker()

    // Notifications, hotkey, onboarding (SPEC §8, §9, §6.6). Switches persist in `app_settings`.
    private(set) var appSettings = AppSettings()
    let notifier = Notifier()
    /// Pending → submitted delivery against the durable ledger (M4-R02/R03).
    private var dispatcher: NotificationDispatcher!
    private var resetMemory: [String: Date] = [:]
    private var loggedCounts: [AttentionBucket: Int] = [:]
    private(set) var hotkeyStatus: OSStatus = 0
    private var keyMonitor: Any?

    // Thread summaries (M8, SPEC 2.9): off until the owner turns them on. The service holds the
    // request only while a CLI runs; the model sees summary text and metadata only.
    private(set) var summarySettings = SummarySettings()
    private(set) var summaries: [String: ThreadSummary] = [:]
    private(set) var summaryStatus = SummaryStatus()
    private var summaryService: SummaryService!
    private var summaryTask: Task<Void, Never>?

    /// The app's one model, for receipt captures (`ReceiptSnapshot`).
    private(set) static weak var current: AppModel?

    init() {
        var store: Store?
        // Test hooks come only from the launch arguments, and only as a complete scratch
        // configuration (M1-07, `TestHooks`). A partial one stops the app before any store opens.
        // One Lighthouse at a time: a second copy (another build, or one LaunchServices starts for a
        // notification click) would double notifications and store writers. It leaves at once.
        // A complete scratch test configuration has its own store, so it may run beside the user's
        // copy; the store lock below still allows one writer per store (M9 F3).
        let hooks = TestHooks.parse(arguments: CommandLine.arguments)
        if case .rejected(let reason) = hooks {
            log.error("test configuration rejected: \(reason, privacy: .public)")
            exit(64)
        }
        let testMode = if case .test = hooks { true } else { false }
        if !testMode, let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0 != NSRunningApplication.current }) {
            log.notice("another Lighthouse is running; this copy exits")
            exit(0)
        }
        let storeURL = if case .test(let url, _, _) = hooks { url } else { Store.defaultURL }
        guard let lock = StoreLock(store: storeURL) else {
            log.notice("another Lighthouse holds this store; this copy exits")
            exit(0)
        }
        storeLock = lock
        do {
            if case .test(let url, _, _) = hooks { store = try Store(url: url) } else { store = try Store() }
        } catch {
            storeError = "\(error)"
            log.error("store unavailable")
        }
        self.store = store
        if case .test(_, let claude, let codex) = hooks {
            // Scratch sources only: the real T3 database is never mixed with fixture data.
            let t3Home = TestHooks.scratchT3Home(arguments: CommandLine.arguments)
            self.engine = Engine(collectors: [ClaudeCodeCollector(root: claude, store: store), CodexCollector(codexHome: codex, store: store)],
                                 store: store, t3: t3Home.map { T3Collector(reader: T3Reader(t3Home: $0)) },
                                 t3NotRead: "Not read in test mode: T3 titles and subagent nesting are missing (pass -LighthouseTestT3Home with a scratch T3 home)")
            if t3Home != nil { log.notice("scratch T3 source in use") }
            log.notice("test sources in use")
        } else {
            self.engine = Engine.live(store: store)
        }
        prefs = (try? store?.loadPrefs()) ?? ProjectPrefs()
        overrides = (try? store?.loadOverrides()) ?? [:]
        bindings = (try? store?.loadBindings()) ?? []
        usageSettings = (try? store?.loadUsageSettings()) ?? UsageSettings()
        appSettings = (try? store?.loadAppSettings()) ?? AppSettings()
        summarySettings = (try? store?.loadSummarySettings()) ?? SummarySettings()
        if let provider = TestHooks.summaryProvider(arguments: CommandLine.arguments) {
            // Test mode only (scratch store): receipts turn summaries on without clicking Settings.
            summarySettings.provider = provider
            try? store?.saveSummarySettings(summarySettings)
            log.notice("summary provider from test arguments provider=\(provider.rawValue, privacy: .public)")
        }
        summaryService = SummaryService(settings: summarySettings, store: store, scratch: SummaryService.defaultScratch)
        let notifier = self.notifier
        dispatcher = NotificationDispatcher(store: store, send: { planned in await notifier.submit(planned) },
                                            alreadyShown: { await notifier.shownIdentifiers() })
        applyLaunchArguments()
        notifier.onOpen = { [weak self] root, provider in self?.openFromNotification(project: root, provider: provider) }
        Task { [weak self] in await self?.checkNotificationPermission() }
        Hotkey.shared.action = { PanelControl.toggle() }
        hotkeyStatus = Hotkey.shared.register(appSettings.hotkey)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = event.window, PanelWarmup.isPanel(window) else { return event }
            return MainActor.assumeIsolated { self.handleKey(event) } ? nil : event
        }
        start()
        startUsage()
        Task { [weak self] in await self?.refreshSummaries() }
        Self.current = self
        visibility = PanelVisibility { [weak self] visible, warmup in
            self?.panelVisibilityChanged(visible: visible, warmup: warmup)
        }

    }

    // MARK: Derived

    var router: OpenRouter { OpenRouter(overrides: overrides) }

    /// The store in use (the scratch store in test mode).
    var storePath: String { store?.url.path ?? Store.defaultURL.path }

    /// The shelf as displayed: frozen placement while open, live data in each row, narrowed to the
    /// projects with an open item of the attention filter's kind.
    var shelf: Shelf {
        var shelf = session.displayed(liveShelf)
        // Quiet is hidden unless the owner turns it on; search still reaches its projects.
        if !appSettings.showQuiet { shelf[.quiet] = [] }
        guard let filter = attentionFilter else { return shelf }
        var filtered = Shelf.empty
        for group in ShelfGroup.allCases {
            filtered[group] = shelf[group].filter { $0.attentionItems.contains { $0.kind.bucket == filter } }
        }
        return filtered
    }

    /// Open, unacknowledged items per strip bucket (`◆ Needs you 2 · Gone quiet 1`).
    var attentionCounts: [AttentionBucket: Int] { AttentionRules.counts(liveShelf.all) }
    var attentionTotal: Int { attentionCounts.values.reduce(0, +) }

    var searchHits: [SearchHit] { ShelfBuilder.search(searchText, in: liveShelf.all) }

    var hasProjects: Bool { !liveShelf.all.isEmpty }
    func project(_ root: String) -> ProjectSummary? { liveShelf.all.first { $0.identity.root == root } }

    /// Readings of enabled providers, in provider order.
    func usage(for provider: Provider) -> ProviderUsage? { usage.first { $0.provider == provider } }

    /// Local tokens of `provider` this window, per project (SPEC §5.5, §6.3).
    func attribution(for provider: Provider) -> LocalTokenAttribution {
        LocalTokenAttribution(provider: provider, usage: usage(for: provider), projects: liveShelf.all, statuses: snapshot.statuses, now: now)
    }

    var coverageNote: String? {
        let windowed = snapshot.statuses.reduce(0) { $0 + $1.filesInWindow }
        let indexed = snapshot.statuses.reduce(0) { $0 + $1.filesIndexed }
        guard snapshot.indexing, windowed > 0 else { return nil }
        return "Indexing \(indexed)/\(windowed) sessions"
    }

    /// True until the first pass of this run has read the sources.
    private(set) var isLoading = true

    // MARK: Lifecycle

    private func start() {
        let touched = self.touched
        let waker = self.waker
        watcher = DirectoryWatcher(paths: engine.watchedPaths, latency: 5, filter: { $0.hasSuffix(".jsonl") }) { paths in
            touched.add(paths)
            waker.wake()
        }
        let engine = self.engine
        let summaryService: SummaryService = self.summaryService
        let summariesOn = summarySettings.isOn
        // Indexing runs at utility QoS so the panel stays responsive while it reads (SPEC §3.2).
        // M1-01: build the panel window invisibly at launch. Prefer to do it right after the last
        // known shelf is published, so the first full render of the rows also happens inside the
        // warm-up; never later than 0.5 s after launch, so a slow restore cannot leave the window cold.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.warmUpOnce() }
        Task(priority: .userInitiated) { [weak self] in
            let restored = await engine.restoredSnapshot()
            if !restored.projects.isEmpty { await Self.deliver(restored, to: self) }
            await MainActor.run { self?.warmUpOnce() }
        }
        Task(priority: .utility) { [weak self] in
            // Before the first observed pass, so no wording guess runs while the model judges (SPEC 2.10).
            await engine.setReplyJudgments(summariesOn ? ReplyJudgment.from(await summaryService.all()) : nil)
            let started = Date()
            let first = await engine.indexToCompletion(progressInterval: 5) { [weak self] snapshot in
                await Self.deliver(snapshot, to: self)
            }
            let seconds = Date().timeIntervalSince(started)
            let bytes = await engine.bytesReadTotal
            log.notice("index complete seconds=\(seconds, format: .fixed(precision: 1), privacy: .public) bytes=\(bytes, privacy: .public)")
            await Self.deliver(first, to: self)
            // Live: FSEvents (changed files only) plus a 60 s full rescan for dropped events (SPEC §3.1).
            var lastFull = Date()
            while !Task.isCancelled {
                await waker.wait(timeout: 60)
                // Bound live work: at most one pass per 10 s even while agents write constantly.
                try? await Task.sleep(for: .seconds(10))
                let changed = touched.take()
                let full = Date().timeIntervalSince(lastFull) >= 60
                let before = await engine.changeCount
                _ = await engine.pass(scope: full ? .full : .paths(changed), resolve: false)
                if full {
                    lastFull = Date()
                    if let t3 = await engine.t3 {
                        let attempts = await t3.attempts, reads = await t3.reads, skips = await t3.unchangedSkips, error = await t3.lastError
                        log.notice("t3 poll attempts=\(attempts, privacy: .public) reads=\(reads, privacy: .public) unchangedSkips=\(skips, privacy: .public) error=\(error ?? "none", privacy: .public)")
                    }
                }
                // Nothing new was read (JSONL bytes or T3 data): keep the shelf; ages refresh from the panel clock.
                let after = await engine.changeCount
                guard full || after != before else { continue }
                await Self.deliver(await engine.resolvedSnapshot(), to: self)
            }
        }
    }

    /// Builds the shelf off the main thread, then publishes, so a click during indexing is not
    /// queued behind sorting (SPEC §3.2 panel-open budget).
    private nonisolated static func deliver(_ snapshot: Snapshot, to model: AppModel?) async {
        guard let model else { return }
        let (prefs, options) = await MainActor.run { (model.prefs, model.appSettings.shelfOptions) }
        let shelf = ShelfBuilder.build(projects: snapshot.projects, prefs: prefs, options: options, now: Date())
        await MainActor.run { model.publish(snapshot, shelf: shelf) }
    }

    private func publish(_ snapshot: Snapshot, shelf: Shelf? = nil) {
        guard !snapshot.projects.isEmpty || !snapshot.indexing || self.snapshot.projects.isEmpty else {
            // Catch-up passes without resolution carry no projects; keep showing the last shelf.
            self.snapshot.statuses = snapshot.statuses
            self.snapshot.indexing = snapshot.indexing
            return
        }
        // A restored (launch) snapshot never replaces data from a live pass.
        if snapshot.checkedAt == nil && !isLoading { return }
        // Only assign what changed: every assignment re-renders the views that read it, and a
        // re-render of the whole shelf on the main thread can delay a click (M1-01).
        self.snapshot = snapshot
        if snapshot.checkedAt != nil && isLoading { isLoading = false }
        let next = shelf ?? ShelfBuilder.build(projects: snapshot.projects, prefs: prefs, options: appSettings.shelfOptions, now: Date())
        if next != liveShelf {
            liveShelf = next
            now = Date()
            if session.isOpen, session.displayed(next).all.map(\.id) != next.all.map(\.id) {
                log.notice("placement held while open: live order differs")
            }
        }
        let counts = attentionCounts
        if counts != loggedCounts {
            loggedCounts = counts
            log.notice("attention needsYou=\(counts[.needsYou] ?? 0, privacy: .public) goneQuiet=\(counts[.goneQuiet] ?? 0, privacy: .public)")
        }
        if snapshot.checkedAt != nil {
            evaluateNotifications()
            considerSummaries()
        }
    }

    // MARK: Summaries (M8)

    /// One scheduling step after each published pass (every ≤ 70 s while idle). With summaries off
    /// nothing happens: no transcript read, no process. Due threads are summarized one at a time,
    /// back to back, until none is due or the hourly cap is reached.
    func considerSummaries() {
        guard summarySettings.isOn, summaryTask == nil else { return }
        let candidates = SummaryCandidate.from(liveShelf.all)
        let service: SummaryService = summaryService
        summaryTask = Task { [weak self] in
            while let report = await service.step(candidates) {
                Self.logSummary(report, calls: await service.callsInLastHour())
                await self?.refreshSummaries()
                if Task.isCancelled { break }
            }
            await MainActor.run { self?.summaryTask = nil }
        }
    }

    /// Metadata only: never the request, the transcript, the CLI output or the summary text.
    private nonisolated static func logSummary(_ r: SummaryService.Report, calls: Int) {
        log.notice("summary step outcome=\(r.outcome.rawValue, privacy: .public) provider=\(r.provider.rawValue, privacy: .public) model=\(r.model, privacy: .public) called=\(r.called, privacy: .public) exit=\(r.exitCode.map(String.init) ?? "none", privacy: .public) seconds=\(r.seconds, format: .fixed(precision: 2), privacy: .public) requestBytes=\(r.requestBytes, privacy: .public) stdoutBytes=\(r.stdoutBytes, privacy: .public) stderrBytes=\(r.stderrBytes, privacy: .public) callsLastHour=\(calls, privacy: .public)")
    }

    func refreshSummaries() async {
        let service: SummaryService = summaryService
        let all = await service.all()
        let status = SummaryStatus(callsLastHour: await service.callsInLastHour(), last: await service.lastReport?.outcome)
        if all != summaries {
            summaries = all
            await pushReplyJudgments()
        }
        if status != summaryStatus { summaryStatus = status }
    }

    /// Hands the model's "needs the owner" judgments to the engine (or nil with summaries off, for the
    /// wording fallback) and re-resolves the shelf when they changed.
    func pushReplyJudgments() async {
        let judgments = summarySettings.isOn ? ReplyJudgment.from(summaries) : nil
        guard judgments != lastJudgments else { return }
        lastJudgments = judgments
        let engine = self.engine
        await engine.setReplyJudgments(judgments)
        await Self.deliver(await engine.resolvedSnapshot(), to: self)
    }
    private var lastJudgments: [String: ReplyJudgment]?? = .none

    /// The summary to show for a thread, only while summaries are on.
    func summary(for thread: SessionThread) -> ThreadSummary? {
        summarySettings.isOn ? summaries[thread.id] : nil
    }

    func setSummarySettings(_ settings: SummarySettings) {
        var settings = settings
        settings.hourlyCap = SummarySettings.clampCap(settings.hourlyCap)
        if !SummarySettings.validModel(settings.claudeModel) { settings.claudeModel = summarySettings.claudeModel }
        if !SummarySettings.validModel(settings.chatgptModel) { settings.chatgptModel = summarySettings.chatgptModel }
        let turnedOn = settings.isOn && !summarySettings.isOn
        summarySettings = settings
        try? store?.saveSummarySettings(settings)
        log.notice("summary settings provider=\(settings.provider.rawValue, privacy: .public) model=\(settings.model ?? "none", privacy: .public) cap=\(settings.hourlyCap, privacy: .public)")
        let service: SummaryService = summaryService
        Task { [weak self] in
            await service.apply(settings)
            await self?.refreshSummaries()
            await self?.pushReplyJudgments()
            if turnedOn { self?.considerSummaries() }
        }
    }

    func clearSummaries() {
        let service: SummaryService = summaryService
        Task { [weak self] in
            await service.clear()
            await self?.refreshSummaries()
        }
        log.notice("summaries cleared")
    }

    /// The CLI Lighthouse would run for a provider, if installed.
    func summaryCLI(_ provider: SummaryProvider) -> String? { CLILocator().locate(provider) }

    // MARK: Notifications (SPEC §8)

    /// Plans and delivers notifications for open incidents and usage events. Every decision is
    /// recorded first, so an incident is notified at most once, across restarts.
    func evaluateNotifications(now: Date = Date()) {
        // Wait for the system's permission answer; without permission nothing can be delivered,
        // so incidents are recorded as not delivered (and never delivered later).
        guard notifier.statusKnown, notifier.status != .notDetermined || !appSettings.notificationsOn else { return }
        var settings = appSettings
        if !notifier.isAuthorized { settings.notificationsOn = false }
        let thresholds = UsageAlerts.thresholdAlerts(usage, now: now)
        let resets = UsageAlerts.resetAlerts(previous: resetMemory, readings: usage)
        resetMemory = resets.current
        let outage = snapshot.t3Outage?.alert(now: now).map { [$0] } ?? []
        let input = NotificationPlanner.Input(projects: liveShelf.all, usageAlerts: thresholds.deliver + resets.alerts + outage,
                                              usageCovered: thresholds.covered, settings: settings, now: now)
        let paused = appSettings.alertsPaused
        let dispatcher: NotificationDispatcher = self.dispatcher
        Task {
            let report = await dispatcher.evaluate(input)
            guard report.recorded > 0 || report.ledgerUnavailable else { return }
            log.notice("notifications planned deliver=\(report.submitted.count + report.rejected.count, privacy: .public) submitted=\(report.submitted.count, privacy: .public) rejected=\(report.rejected.count, privacy: .public) recorded=\(report.recorded, privacy: .public) suppressed=\(report.suppressed, privacy: .public) paused=\(paused, privacy: .public) ledgerUnavailable=\(report.ledgerUnavailable, privacy: .public) markFailed=\(report.markFailed, privacy: .public)")
        }
    }

    /// At launch: the owner opted in but this copy of the app has no answer from macOS yet (a new
    /// build, or permission reset): ask again through the system prompt.
    private func checkNotificationPermission() async {
        await notifier.refreshStatus()
        if appSettings.notificationsOn && notifier.status == .notDetermined {
            _ = await notifier.requestAuthorization()
        }
        log.notice("notification permission authorized=\(self.notifier.isAuthorized, privacy: .public)")
        await notifier.logHeld()
        evaluateNotifications()
    }

    private func openFromNotification(project root: String?, provider: Provider?) {
        if let root { route = .project(root) } else if let provider { route = .provider(provider) }
        PanelControl.open()
    }

    func saveAppSettings() {
        try? store?.saveAppSettings(appSettings)
    }

    /// Turning notifications on asks for permission through the system prompt (opt-in, SPEC §8).
    func setNotifications(_ on: Bool) {
        appSettings.notificationsOn = on
        saveAppSettings()
        guard on else { return }
        Task {
            _ = await notifier.requestAuthorization()
            notifierStatusTick += 1
        }
    }

    /// Bumped when the system permission status may have changed, so Settings re-reads it.
    var notifierStatusTick = 0

    func setCategory(_ category: NotificationCategory, _ on: Bool) {
        if on { appSettings.categories.insert(category) } else { appSettings.categories.remove(category) }
        saveAppSettings()
    }

    func setAlertsPaused(_ paused: Bool) {
        appSettings.alertsPaused = paused
        saveAppSettings()
        log.notice("alerts paused=\(paused, privacy: .public)")
    }

    func setHotkey(_ choice: HotkeyChoice) {
        appSettings.hotkey = choice
        saveAppSettings()
        hotkeyStatus = Hotkey.shared.register(choice)
    }

    /// Owner shelf settings apply at once, even while the panel is open (like pin/pause).
    func setRecentlyCompletedHours(_ hours: Int) {
        appSettings.recentlyCompletedHours = hours
        saveAppSettings()
        rebuild()
        session.refreeze(live: liveShelf)
    }

    func setShowQuiet(_ on: Bool) {
        appSettings.showQuiet = on
        saveAppSettings()
    }

    func toggleUsageCompact() {
        appSettings.usageCompact.toggle()
        saveAppSettings()
    }

    func finishOnboarding() {
        appSettings.onboarded = true
        saveAppSettings()
    }

    var loginItemTick = 0
    func setLoginItem(_ on: Bool) {
        LoginItem.set(on)
        loginItemTick += 1
    }

    private var warmedUp = false

    private func warmUpOnce() {
        guard !warmedUp else { return }
        warmedUp = true
        PanelWarmup.run()
    }

    private func rebuild() {
        liveShelf = ShelfBuilder.build(projects: snapshot.projects, prefs: prefs, options: appSettings.shelfOptions, now: Date())
    }

    func refreshNow() { waker.wake() }

    // MARK: Attention (SPEC §5.4; local only, never sent to an agent)

    /// The open, unacknowledged incident for a subagent, if any.
    func openItem(forSubagent id: String) -> AttentionItem? {
        liveShelf.all.lazy.flatMap(\.attentionItems).first { $0.subagentId == id }
    }

    /// The open, unacknowledged stall of a thread, if any.
    func openStall(forThread id: String) -> AttentionItem? {
        liveShelf.all.lazy.flatMap(\.attentionItems).first { $0.threadId == id && $0.kind == .stalledThread }
    }

    /// Hides one incident identity; a later state entry creates a new item (SPEC §5.4).
    func acknowledge(_ item: AttentionItem) {
        try? store?.acknowledge(item.id)
        let engine = self.engine
        Task { [weak self] in await Self.deliver(await engine.resolvedSnapshot(), to: self) }
    }

    // MARK: Usage

    private func startUsage() {
        // Test mode with `-LighthouseTestUsage <fixture>`: canned readings, no monitor, no request.
        if let fixture = TestHooks.usageFixture(arguments: CommandLine.arguments, now: Date()) {
            log.notice("usage fixture in use providers=\(fixture.count, privacy: .public)")
            usage = fixture
            nav.providers = fixture.map(\.provider)
            glyph = UsageGlyphState(readings: fixture, now: Date())
            logPace(fixture, now: Date())
            return
        }
        let monitor = usageMonitor
        let waker = usageWaker
        Task { [weak self] in
            while !Task.isCancelled {
                guard let enabled = self?.usageSettings.enabled else { return }
                for provider in Provider.allCases where enabled.contains(provider) {
                    let reading = await monitor.poll(provider)
                    log.notice("usage poll provider=\(provider.rawValue, privacy: .public) result=\(reading?.lastFailure?.kind ?? "ok", privacy: .public)")
                }
                await self?.publishUsage()
                await waker.wait(timeout: UsageMonitor.defaultPollInterval)
            }
        }
        // The glyph's freshness, reset and stale marks follow the clock even while the panel is closed.
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await self?.publishUsage()
            }
        }
    }

    private func publishUsage() async {
        let now = Date()
        let enabled = usageSettings.enabled
        let readings = await usageMonitor.readings(now: now).filter { enabled.contains($0.provider) }
        let trackers = await usageMonitor.trackers.filter { enabled.contains($0.key) }.map(\.value)
        let glyph = UsageGlyphState(readings: readings, trackers: trackers, now: now)
        if readings != usage {
            usage = readings
            nav.providers = readings.map(\.provider)
            logPace(readings, now: now)
            evaluateNotifications(now: now)
        }
        if glyph != self.glyph { self.glyph = glyph }
    }

    /// One line per shown window with the pace inputs and outputs (M6 C4 recompute evidence).
    private func logPace(_ readings: [ProviderUsage], now: Date) {
        for reading in readings {
            for window in reading.displayWindows(now: now) {
                log.notice("\(UsageText.paceLog(provider: reading.provider, window: window, now: now), privacy: .public)")
            }
        }
    }

    func setUsage(_ provider: Provider, enabled: Bool) {
        if enabled { usageSettings.enabled.insert(provider) } else { usageSettings.enabled.remove(provider) }
        try? store?.saveUsageSettings(usageSettings)
        Task {
            if !enabled { await usageMonitor.disable(provider) }
            await publishUsage()
            usageWaker.wake()
        }
    }

    func setShowWorstPercent(_ show: Bool) {
        usageSettings.showWorstPercent = show
        try? store?.saveUsageSettings(usageSettings)
    }

    /// Owner retry: forget the cached token and any Keychain denial, then poll now.
    func retryUsage(_ provider: Provider) {
        Task {
            await usageMonitor.retry(provider)
            usageWaker.wake()
        }
    }

    func openProject(_ root: String, from provider: Provider) {
        changeRoutes { $0.openProject(root, from: provider) }
    }

    /// Back from a pushed page: a project opened from a provider page returns there.
    func pop() {
        changeRoutes { $0.pop() }
    }

    /// Project rows of a provider page, in display order.
    func providerProjectRoots(_ provider: Provider) -> [String] {
        attribution(for: provider).projects.map(\.project.identity.root)
    }

    var providerFocus: Int? { routes.providerFocus }

    var panelOpen: Bool { session.isOpen }
    private var clock: Task<Void, Never>?

    /// Each real show and hide of the panel window (`PanelVisibility`). The warm-up show is ignored.
    func panelVisibilityChanged(visible: Bool, warmup: Bool) {
        if visible {
            guard !warmup, !session.isOpen else { return }
            session.show(live: liveShelf, warmup: false)
            log.notice("panel shown")
            let height = panelContentHeight
            DispatchQueue.main.async { PanelControl.fit(contentHeight: height) }
            ReceiptSnapshot.captureSoon(model: self)
            now = Date()
            // Ages tick every 15 s only while the panel is open.
            clock?.cancel()
            clock = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(15))
                    guard !Task.isCancelled else { return }
                    self?.now = Date()
                }
            }
        } else {
            guard session.isOpen else { return }
            session.hide()
            log.notice("panel hidden")
            clock?.cancel()
            clock = nil
            searchText = ""
            searchVisible = false
            searchFocus = nil
        }
    }

    // MARK: Owner actions (local preferences only)

    func togglePin(_ root: String) {
        if let i = prefs.pinned.firstIndex(of: root) { prefs.pinned.remove(at: i) } else { prefs.pinned.append(root) }
        savePrefs()
    }

    func togglePaused(_ root: String) {
        if prefs.paused.remove(root) == nil { prefs.paused.insert(root) }
        savePrefs()
    }

    func toggleArchived(_ root: String) {
        if prefs.archived.remove(root) == nil { prefs.archived.insert(root) }
        savePrefs()
    }

    private func savePrefs() {
        try? store?.savePrefs(prefs)
        rebuild()
        // Pin changes are the user's own action; apply placement now.
        session.refreeze(live: liveShelf)
    }

    func bind(folder: String, to projectRoot: String) {
        try? store?.saveBinding(ProjectBinding(folder: folder, projectRoot: projectRoot))
        bindings = (try? store?.loadBindings()) ?? []
        refreshNow()
    }

    func removeBinding(_ folder: String) {
        try? store?.removeBinding(folder: folder)
        bindings = (try? store?.loadBindings()) ?? []
        refreshNow()
    }

    func setOverride(_ override: OpenOverride?, for app: OwningApp) {
        try? store?.saveOverride(override, for: app)
        overrides = (try? store?.loadOverrides()) ?? [:]
    }

    // MARK: Navigation handoffs (V-OBS: open, reveal, copy only)

    /// A "Needs you" tag was clicked: open that thread in its app.
    func openWaiting(_ thread: SessionThread) {
        log.notice("needs-you open thread=\(thread.id, privacy: .public) app=\(thread.owningApp.rawValue, privacy: .public)")
        perform(router.target(for: thread))
    }

    func perform(_ action: OpenAction) {
        let workspace = NSWorkspace.shared
        switch action {
        case .link(let url, let app):
            workspace.open(url)
            log.info("open link app=\(app.name, privacy: .public)")
        case .app(let app, _):
            guard let appURL = workspace.urlForApplication(withBundleIdentifier: app.bundleIdentifier) else {
                show("\(app.name) is not installed.")
                return
            }
            workspace.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
            show("Opened \(app.name).")
        case .appWithFolder(let appPath, let appName, let folder, _):
            workspace.open([URL(fileURLWithPath: folder)], withApplicationAt: URL(fileURLWithPath: appPath),
                           configuration: NSWorkspace.OpenConfiguration())
            show("Opened \(appName).")
        case .reveal(let path):
            reveal(path)
        }
    }

    func copySessionId(_ id: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(id, forType: .string)
        show("Session ID copied.")
    }

    func reveal(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            show("Folder no longer exists.")
        }
    }

    func chooseBinding(for project: ProjectSummary) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Bind"
        if project.identity.isUnassigned {
            panel.message = "Choose the project folder for \(project.identity.folderPath)"
        } else {
            panel.message = "Choose a folder whose sessions belong to \(project.identity.name)"
        }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if project.identity.isUnassigned {
            bind(folder: project.identity.folderPath, to: url.path)
        } else {
            bind(folder: url.path, to: project.identity.root)
        }
    }

    func show(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    // MARK: Keyboard (SPEC §9): ↑/↓ move, → expand/push, ← collapse/pop, ⏎ primary action

    func moveFocus(_ delta: Int) {
        switch route {
        case .home: nav.move(delta, in: shelf)
        case .project(let root): if let project = project(root) { page.move(delta, in: project, now: now) }
        case .provider(let provider):
            let count = providerProjectRoots(provider).count
            changeRoutes { $0.moveProviderFocus(delta, count: count) }
        }
        log.notice("key move focus=\(self.focusName, privacy: .public)")
    }

    func focusRight() {
        switch route {
        case .home: handle(nav.expand(in: shelf))
        case .project:
            if let id = page.focusedThread { expandedThreads.insert(id) } else if page.focused == .earlier { page.showEarlier = true }
        case .provider(let provider): openFocusedProviderProject(provider)
        }
    }

    func focusLeft() {
        switch route {
        case .home: nav.collapse()
        case .project:
            if let id = page.focusedThread, expandedThreads.contains(id) {
                expandedThreads.remove(id)
            } else if page.focused == .earlier && page.showEarlier {
                page.showEarlier = false
            } else {
                pop()
            }
        case .provider: pop()
        }
    }

    func focusPrimary() {
        switch route {
        case .home: handle(nav.activate(in: shelf))
        case .project(let root):
            guard let project = project(root) else { return }
            if let id = page.focusedThread, let thread = project.threads.first(where: { $0.id == id }) {
                perform(router.target(for: thread))
            } else if page.focused == .earlier {
                page.showEarlier.toggle()
            }
        case .provider(let provider): openFocusedProviderProject(provider)
        }
    }

    /// ⏎ / → on a provider page: push the focused project row (`openProject`; Back returns here).
    private func openFocusedProviderProject(_ provider: Provider) {
        let roots = providerProjectRoots(provider)
        changeRoutes { $0.activateProviderFocus(roots: roots) }
    }

    /// Focus as a log-safe name: the kind of stop and its position, never a title or path.
    var focusName: String {
        switch route {
        case .home:
            guard let focused = nav.focused else { return "home:none" }
            let index = nav.stops(in: shelf).firstIndex(of: focused) ?? -1
            switch focused {
            case .provider(let p): return "home:\(index):provider:\(p.rawValue)"
            case .groupHeader(let g): return "home:\(index):group:\(g.rawValue)"
            case .project: return "home:\(index):project"
            case .thread: return "home:\(index):thread"
            case .showAll: return "home:\(index):showAll"
            case .morePins: return "home:\(index):morePins"
            }
        case .project(let root):
            guard let project = project(root), let focused = page.focused else { return "project:none" }
            let index = PageNavigation.stops(project, showEarlier: page.showEarlier, now: now).firstIndex(of: focused) ?? -1
            return "project:\(index):\(focused == .earlier ? "earlier" : "thread")"
        case .provider(let p): return "provider:\(p.rawValue):\(routes.providerFocus.map(String.init) ?? "none")"
        }
    }

    func showMorePins() {
        nav.showMorePins(in: shelf)
    }

    /// Panel keys (SPEC §9), from a local event monitor on the panel window so they work whatever
    /// SwiftUI view holds focus. Returns true when the key was handled. ⌘, stays with the header's SettingsButton.
    func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let searching = searchVisible && route == .home
        if mods == .command {
            switch key {
            case "f": openSearch(""); return true
            case "o": openFocused(); return true
            case "p": pinFocused(); return true
            case "[": if route != .home { pop() }; return true
            default: return false
            }
        }
        guard mods.subtracting(.shift).isEmpty else { return false }
        if event.keyCode == 96, ReceiptSnapshot.captureStep() { return true }   // F5, snapshot mode only
        switch event.keyCode {
        case 53: escape(); return true                                   // Esc
        case 125: searching && !searchText.isEmpty ? moveSearch(1) : moveFocus(1); return true     // ↓
        case 126: searching && !searchText.isEmpty ? moveSearch(-1) : moveFocus(-1); return true   // ↑
        case 124: if searching { return false }; focusRight(); return true                         // →
        case 123: if searching { return false }; focusLeft(); return true                          // ←
        case 36, 76: searching ? openSearchHit() : focusPrimary(); return true                    // ⏎
        default:
            // Typing on the home shelf starts a search (SPEC §6.2 item 4). Keys typed before the
            // new field takes focus are added to the query, so fast typing loses nothing.
            guard route == .home, mods.isEmpty || mods == .shift,
                  let chars = event.characters, chars.count == 1, chars.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) })
            else { return false }
            if !searchVisible {
                openSearch(chars)
                return true
            }
            guard !(event.window?.firstResponder is NSTextView) else { return false }
            searchText += chars
            searchFocusRequest += 1
            return true
        }
    }

    /// Esc: clear search → pop → close (SPEC §9).
    func escape() {
        if searchVisible && route == .home {
            searchText = ""
            searchVisible = false
            searchFocus = nil
        } else if route != .home {
            pop()
        } else if attentionFilter != nil {
            attentionFilter = nil
        } else {
            PanelControl.close()
        }
        log.notice("key esc route=\(self.routeName, privacy: .public)")
    }

    var routeName: String {
        switch route {
        case .home: searchVisible ? "search" : "home"
        case .project: "project"
        case .provider: "provider"
        }
    }

    /// Bumped to ask the search field to take focus with the caret at the end.
    var searchFocusRequest = 0

    func openSearch(_ initial: String) {
        guard route == .home else { route = .home; return openSearch(initial) }
        searchVisible = true
        searchText = initial
        searchFocus = nil
        searchFocusRequest += 1
    }

    private func moveSearch(_ delta: Int) {
        let count = searchHits.count
        guard count > 0 else { return }
        searchFocus = min(max((searchFocus ?? -1) + delta, 0), count - 1)
    }

    func openSearchHit() {
        let hits = searchHits
        guard !hits.isEmpty else { return }
        let hit = hits[min(searchFocus ?? 0, hits.count - 1)]
        route = .project(hit.project.identity.root)
        if let thread = hit.thread {
            expandedThreads.insert(thread.id)
            page.focused = .thread(thread.id)
        }
    }

    /// ⌘O: the primary Open of the focused row, or of the project page.
    func openFocused() {
        switch route {
        case .home:
            if case .thread(let root, let id)? = nav.focused, let thread = project(root)?.threads.first(where: { $0.id == id }) {
                perform(router.target(for: thread))
            } else if let root = nav.focusedProject, let project = project(root) {
                perform(router.primaryTarget(for: project).action)
            }
        case .project(let root):
            guard let project = project(root) else { return }
            if let id = page.focusedThread, let thread = project.threads.first(where: { $0.id == id }) {
                perform(router.target(for: thread))
            } else {
                perform(router.primaryTarget(for: project).action)
            }
        case .provider: break
        }
    }

    /// ⌘P: pin or unpin the focused project, or the project page's project.
    func pinFocused() {
        let root: String?
        switch route {
        case .home: root = nav.focusedProject
        case .project(let r): root = r
        case .provider: root = nil
        }
        guard let root, let project = project(root), !project.identity.isUnassigned else { return }
        togglePin(root)
        log.notice("key pin pinned=\(self.prefs.pinned.contains(root), privacy: .public)")
    }

    private func handle(_ outcome: ShelfNavigation.Outcome) {
        switch outcome {
        case .none: break
        case .push(let root): route = .project(root)
        case .pushProvider(let provider): route = .provider(provider)
        case .openThread(let root, let id):
            if let thread = project(root)?.threads.first(where: { $0.id == id }) { perform(router.target(for: thread)) }
        }
    }

    // MARK: Screenshot states (used for receipts; no effect unless passed at launch)

    private func applyLaunchArguments() {
        let defaults = UserDefaults.standard
        if let root = defaults.string(forKey: "LighthouseInitialProject") {
            route = .project(root)
            expandedThreads = defaults.string(forKey: "LighthouseExpandFirstThread") != nil ? ["first"] : []
        }
        if let root = defaults.string(forKey: "LighthouseExpandProject") { expandedProject = root }
        if let raw = defaults.string(forKey: "LighthouseInitialProvider"), let provider = Provider(rawValue: raw) { route = .provider(provider) }
        // Receipt screenshots of both color modes (launch argument only).
        if let mode = defaults.string(forKey: "LighthouseAppearance") {
            DispatchQueue.main.async { NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua) }
        }
    }

    /// Resolves the "first" placeholder from launch arguments once data exists.
    func resolveLaunchExpansion(for project: ProjectSummary) {
        if expandedThreads.remove("first") != nil, let first = project.threads.first {
            expandedThreads.insert(first.id)
        }
    }
}

/// Summary activity for Settings: counts and the last outcome kind only.
struct SummaryStatus: Equatable {
    var callsLastHour = 0
    var last: SummaryService.Report.Outcome?
}

/// Paths reported by FSEvents since the last pass.
final class TouchedPaths: @unchecked Sendable {
    private let lock = NSLock()
    private var paths = Set<String>()

    func add(_ new: [String]) { lock.lock(); paths.formUnion(new); lock.unlock() }

    func take() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        let result = paths
        paths.removeAll()
        return result
    }
}

/// Wakes the live loop early. `wait` returns after `timeout` or on the first `wake()`; a wake that
/// arrives while no one waits is kept for the next `wait`.
final class Waker: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false
    private var sleeper: Task<Void, Never>?

    func wait(timeout: Double) async {
        guard let task = arm(timeout: timeout) else { return }
        await task.value
        lock.withLock {
            sleeper = nil
            pending = false
        }
    }

    /// Returns nil when a wake is already pending.
    private func arm(timeout: Double) -> Task<Void, Never>? {
        lock.withLock {
            if pending {
                pending = false
                return nil
            }
            let task = Task<Void, Never> { try? await Task.sleep(for: .seconds(timeout)) }
            sleeper = task
            return task
        }
    }

    func wake() {
        lock.withLock {
            pending = true
            sleeper?.cancel()
        }
    }
}
