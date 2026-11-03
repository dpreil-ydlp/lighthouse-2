import Foundation

/// Notification categories (SPEC §8), each togglable. Window reset is off by default.
public enum NotificationCategory: String, Sendable, Hashable, CaseIterable, Codable {
    case waiting
    case silent
    case stalled
    case usage
    case reset
    /// T3 unreadable for 10 min after a good read: stall and waiting detection paused (M9 F4).
    case source

    public var title: String {
        switch self {
        case .waiting: "Waiting for you (approval, input or a reply)"
        case .silent: "Subagent silent"
        case .stalled: "Thread stalled"
        case .usage: "Usage crosses 80 % and 95 %"
        case .reset: "Usage window reset"
        case .source: "T3 unreadable (detection paused)"
        }
    }

    init(_ kind: AttentionKind) {
        switch kind {
        case .waitingForOwner: self = .waiting
        case .silentSubagent: self = .silent
        case .stalledThread: self = .stalled
        }
    }
}

/// Owner switches for notifications and the panel (persisted in `app_settings`; no content).
public struct AppSettings: Sendable, Hashable {
    /// Opt-in master switch (SPEC §8): nothing is delivered until the owner turns it on.
    public var notificationsOn = false
    public var categories: Set<NotificationCategory> = [.waiting, .silent, .stalled, .usage, .source]
    /// Footer "Pause alerts": suppresses delivery, never detection.
    public var alertsPaused = false
    public var onboarded = false
    public var hotkey: HotkeyChoice = .controlOptionSpace
    /// Hours a stopped project stays in "Recently completed" before it moves to Quiet.
    public var recentlyCompletedHours = ShelfOptions.defaultHours
    /// Quiet is hidden from the shelf unless the owner turns it on; search still finds it.
    public var showQuiet = false
    /// Usage block shows one line per provider (default); the USAGE header toggles the detail view.
    public var usageCompact = true

    public init() {}

    public var shelfOptions: ShelfOptions { ShelfOptions(recentlyCompletedHours: recentlyCompletedHours) }

    init(values: [String: Int]) {
        notificationsOn = values["notify.on"] == 1
        categories = Set(NotificationCategory.allCases.filter { category in
            values["notify.\(category.rawValue)"].map { $0 == 1 } ?? AppSettings().categories.contains(category)
        })
        alertsPaused = values["notify.paused"] == 1
        onboarded = values["onboarded"] == 1
        hotkey = values["hotkey"].flatMap(HotkeyChoice.init(rawValue:)) ?? .controlOptionSpace
        recentlyCompletedHours = values["shelf.recentHours"].map { max($0, 0) } ?? ShelfOptions.defaultHours
        showQuiet = values["shelf.showQuiet"] == 1
        // Stored as "usage.detailed" so a value saved by 0.0.5 (when detail was the default) is ignored.
        usageCompact = values["usage.detailed"] != 1
    }

    var values: [String: Int] {
        var result = ["notify.on": notificationsOn ? 1 : 0, "notify.paused": alertsPaused ? 1 : 0, "onboarded": onboarded ? 1 : 0,
                      "hotkey": hotkey.rawValue, "shelf.recentHours": recentlyCompletedHours, "shelf.showQuiet": showQuiet ? 1 : 0,
                      "usage.detailed": usageCompact ? 0 : 1]
        for category in NotificationCategory.allCases { result["notify.\(category.rawValue)"] = categories.contains(category) ? 1 : 0 }
        return result
    }

    /// Whether a notification of `category` reaches the owner now.
    public func delivers(_ category: NotificationCategory) -> Bool {
        notificationsOn && !alertsPaused && categories.contains(category)
    }
}

/// Global hotkey presets (SPEC §6.6, §9, configurable). Default ⌃⌥Space, not SPEC's ⌥Space,
/// because ChatGPT's desktop app opens on ⌥Space.
public enum HotkeyChoice: Int, Sendable, Hashable, CaseIterable {
    case off = 0
    case optionSpace = 1
    case controlOptionSpace = 2
    case commandShiftL = 3

    public var label: String {
        switch self {
        case .off: "Off"
        case .optionSpace: "⌥Space"
        case .controlOptionSpace: "⌃⌥Space"
        case .commandShiftL: "⇧⌘L"
        }
    }
}

/// A notification to deliver. Titles and labels are metadata (project name, thread title field,
/// request kind); never message, prompt or request text (V-PRIV). No action buttons (V-OBS).
public struct PlannedNotification: Sendable, Hashable {
    /// Delivery identifier (the first incident it covers).
    public var id: String
    public var title: String
    public var body: String
    public var category: NotificationCategory
    /// Where a click opens the panel: a project page or a provider page.
    public var projectRoot: String?
    public var provider: Provider?
    /// Every incident identity this notification covers (coalesced items).
    public var incidents: [String]
}

/// Where a notification decision stands (SPEC §8, M4-R02/R03). Stored as an integer.
///
/// - `pending`: the decision to notify is durably recorded, but macOS has not accepted the
///   notification yet. It is submitted (again) while the incident is open, at most
///   `NotificationDispatcher.maxAttempts` times, `retryAfter` apart.
/// - `submitted`: macOS accepted it. Never sent again for this incident.
/// - `suppressed`: the incident arose while alerts were off, paused, its category disabled or
///   permission missing. Never sent later.
/// - `failed`: macOS rejected every attempt. Never sent again.
public enum DeliveryState: Int, Sendable, Hashable {
    case suppressed = 0
    case submitted = 1
    case pending = 2
    case failed = 3
}

/// Persisted record of each incident identity a notification was decided for (SPEC §8: one per
/// incident, across restart).
public struct NotificationRecord: Sendable, Hashable {
    public var incident: String
    public var projectRoot: String?
    /// When the decision was first recorded.
    public var at: Date
    public var state: DeliveryState
    public var attempts: Int
    public var lastAttemptAt: Date?
    /// Identifier of the notification the last attempt was claimed under (M9-E01). A notification
    /// Notification Center still holds covers exactly the incidents claimed under its identifier.
    public var notificationId: String?

    public init(incident: String, projectRoot: String?, at: Date, state: DeliveryState, attempts: Int = 0, lastAttemptAt: Date? = nil,
                notificationId: String? = nil) {
        self.incident = incident
        self.projectRoot = projectRoot
        self.at = at
        self.state = state
        self.attempts = attempts
        self.lastAttemptAt = lastAttemptAt
        self.notificationId = notificationId
    }

    public init(incident: String, projectRoot: String?, at: Date, delivered: Bool) {
        self.init(incident: incident, projectRoot: projectRoot, at: at, state: delivered ? .submitted : .suppressed)
    }

    /// macOS accepted the notification for this incident.
    public var delivered: Bool { state == .submitted }

    /// A pending record that may be submitted now.
    func retryable(now: Date) -> Bool {
        state == .pending && attempts < NotificationDispatcher.maxAttempts
            && (lastAttemptAt.map { now.timeIntervalSince($0) >= NotificationDispatcher.retryAfter } ?? true)
    }
}

/// A usage threshold or reset event (SPEC §8: "once per window id and reset").
public struct UsageAlert: Sendable, Hashable {
    public var id: String
    public var category: NotificationCategory
    /// Nil for a source alert (M9 F4): a click opens the panel home.
    public var provider: Provider?
    public var title: String
    public var body: String
}

/// A source outage that pauses detection (M9 F4). Alerted once per outage: the identity is the
/// last good read, which stays the same across failing passes and restarts.
public struct SourceOutage: Sendable, Hashable {
    public var source: SourceKind
    /// The last successful read (persisted in `collector_status`, so it survives a restart).
    public var lastSuccess: Date
    /// The first failed attempt of this run.
    public var failingSince: Date

    public init(source: SourceKind, lastSuccess: Date, failingSince: Date) {
        self.source = source
        self.lastSuccess = lastSuccess
        self.failingSince = failingSince
    }

    /// An outage is alerted after it has lasted this long in this run (v1 CR12b parity: 10 min).
    public static let alertAfter: TimeInterval = 10 * 60

    public var id: String { "source|\(source.rawValue)|\(Int(lastSuccess.timeIntervalSince1970))" }

    /// The alert, once the outage has lasted `alertAfter`. Text names the source only, never the error detail.
    public func alert(now: Date) -> UsageAlert? {
        guard now.timeIntervalSince(failingSince) >= Self.alertAfter else { return nil }
        return UsageAlert(id: id, category: .source, provider: nil, title: "T3 unreadable · detection paused",
                          body: "Stalls and approvals in T3 won’t be detected.")
    }
}

public enum UsageAlerts {
    /// Used-percent thresholds: 20 % and 5 % left (SPEC 2.7 §8). Alert text states percent left.
    public static let thresholds: [Double] = [80, 95]

    /// The reset time in the identity is rounded to 15 min so second-level jitter in a provider's
    /// reported reset never makes a new identity for the same window.
    static func resetKey(_ date: Date?) -> String {
        guard let date else { return "none" }
        return String(Int((date.timeIntervalSince1970 / 900).rounded()))
    }

    /// Threshold crossings in fresh readings. Account change gives new identities (SPEC §5.5).
    /// When one reading crosses both, only the higher alert is returned; both are recorded.
    public static func thresholdAlerts(_ readings: [ProviderUsage], now: Date) -> (deliver: [UsageAlert], covered: [String]) {
        var deliver: [UsageAlert] = []
        var covered: [String] = []
        for reading in readings where reading.status == .fresh {
            for window in reading.displayWindows(now: now) {
                let crossed = thresholds.filter { window.usedPercent >= $0 }
                guard let top = crossed.last else { continue }
                let base = "usage|\(reading.provider.rawValue)|\(reading.accountAlias ?? "-")|\(window.id)|\(resetKey(window.resetsAt))"
                covered += crossed.map { "\(base)|\(Int($0))" }
                let name = window.isPool ? window.label : (window.id == UsageWindow.sessionId ? "session" : "weekly")
                deliver.append(UsageAlert(id: "\(base)|\(Int(top))", category: .usage, provider: reading.provider,
                                          title: "\(reading.provider.displayName) \(name): \(UsageText.left(UsagePace(window: window, now: now)))",
                                          body: top >= 95 ? "5% or less of the \(name) limit left." : "20% or less of the \(name) limit left."))
            }
        }
        return (deliver, covered)
    }

    /// A window whose reset time moved later since the previous reading has reset.
    public static func resetAlerts(previous: [String: Date], readings: [ProviderUsage]) -> (alerts: [UsageAlert], current: [String: Date]) {
        var current: [String: Date] = [:]
        var alerts: [UsageAlert] = []
        for reading in readings where reading.status == .fresh {
            for window in reading.windows where !window.isPool {
                guard let reset = window.resetsAt else { continue }
                let key = "\(reading.provider.rawValue)|\(reading.accountAlias ?? "-")|\(window.id)"
                current[key] = reset
                if let old = previous[key], reset.timeIntervalSince(old) > 15 * 60 {
                    let name = window.id == UsageWindow.sessionId ? "session" : "weekly"
                    alerts.append(UsageAlert(id: "reset|\(key)|\(resetKey(old))", category: .reset, provider: reading.provider,
                                             title: "\(reading.provider.displayName) \(name) window reset",
                                             body: "Now \(Int(min(max(100 - window.usedPercent, 0), 100).rounded()))% left."))
                }
            }
        }
        return (alerts, current)
    }
}

/// Decides which notifications to deliver (SPEC §8). Pure apart from the ledger it is given.
///
/// - One notification per incident identity; the ledger persists across restart.
/// - Coalescing: at most one notification per project per 5 min. New incidents of a project that
///   had a delivery in the last 5 min wait; when the window ends, the ones still open go out
///   together as one notification. Incidents that cleared meanwhile are dropped.
/// - Pause alerts, a disabled category, or notifications off: the incident is recorded as
///   `suppressed` and never delivered later. Detection is unaffected.
/// - A planned delivery is returned as a `pending` record; `NotificationDispatcher` records it
///   durably before submitting and marks it `submitted` only after macOS accepts it. A pending
///   record that may be retried is planned again like a new incident, keeping its attempt count.
public enum NotificationPlanner {
    public static let coalesceWindow: TimeInterval = 5 * 60

    public struct Input: Sendable {
        public var projects: [ProjectSummary]
        public var usageAlerts: [UsageAlert]
        /// Usage identities covered without their own delivery (a lower threshold crossed together).
        public var usageCovered: [String]
        public var settings: AppSettings
        public var now: Date

        public init(projects: [ProjectSummary], usageAlerts: [UsageAlert] = [], usageCovered: [String] = [], settings: AppSettings, now: Date) {
            self.projects = projects
            self.usageAlerts = usageAlerts
            self.usageCovered = usageCovered
            self.settings = settings
            self.now = now
        }
    }

    public static func plan(_ input: Input, ledger: [String: NotificationRecord]) -> (deliver: [PlannedNotification], record: [NotificationRecord]) {
        var deliver: [PlannedNotification] = []
        var record: [NotificationRecord] = []
        let now = input.now
        /// Incidents with a decision that stands: everything except pending records due for a retry.
        func known(_ id: String) -> Bool { ledger[id].map { !$0.retryable(now: now) } ?? false }
        func pending(_ id: String, root: String?) -> NotificationRecord {
            let old = ledger[id]
            return NotificationRecord(incident: id, projectRoot: root, at: old?.at ?? now, state: .pending,
                                      attempts: old?.attempts ?? 0, lastAttemptAt: old?.lastAttemptAt, notificationId: old?.notificationId)
        }

        // Coalescing counts only notifications macOS accepted.
        var lastDelivery: [String: Date] = [:]
        for entry in ledger.values where entry.state == .submitted {
            guard let root = entry.projectRoot else { continue }
            let at = entry.lastAttemptAt ?? entry.at
            lastDelivery[root] = max(lastDelivery[root] ?? .distantPast, at)
        }

        for project in input.projects {
            let root = project.identity.root
            let fresh = project.attentionItems.filter { !known($0.id) }
            guard !fresh.isEmpty else { continue }
            let (allowed, suppressed) = fresh.partitioned { input.settings.delivers(NotificationCategory($0.kind)) }
            record += suppressed.map { NotificationRecord(incident: $0.id, projectRoot: root, at: now, state: .suppressed) }
            guard !allowed.isEmpty else { continue }
            if let last = lastDelivery[root], now.timeIntervalSince(last) < coalesceWindow { continue }
            let ordered = allowed.sorted { ($0.kind == .waitingForOwner ? 0 : 1, $0.enteredAt) < ($1.kind == .waitingForOwner ? 0 : 1, $1.enteredAt) }
            let first = ordered[0]
            let more = ordered.count - 1
            deliver.append(PlannedNotification(
                id: first.id,
                title: first.kind == .waitingForOwner ? "Needs you · \(project.identity.name)" : "Gone quiet · \(project.identity.name)",
                body: first.label + (more > 0 ? " · and \(more) more" : ""),
                category: NotificationCategory(first.kind), projectRoot: root, provider: nil, incidents: ordered.map(\.id)))
            record += ordered.map { pending($0.id, root: root) }
        }

        for alert in input.usageAlerts where !known(alert.id) {
            guard input.settings.delivers(alert.category) else {
                record.append(NotificationRecord(incident: alert.id, projectRoot: nil, at: now, state: .suppressed))
                continue
            }
            record.append(pending(alert.id, root: nil))
            deliver.append(PlannedNotification(id: alert.id, title: alert.title, body: alert.body, category: alert.category,
                                               projectRoot: nil, provider: alert.provider, incidents: [alert.id]))
        }
        for id in input.usageCovered where ledger[id] == nil && !record.contains(where: { $0.incident == id }) {
            record.append(NotificationRecord(incident: id, projectRoot: nil, at: now, state: .suppressed))
        }
        return (deliver, record)
    }

    /// Every incident identity the input still describes as open.
    public static func openIncidents(_ input: Input) -> Set<String> {
        Set(input.projects.flatMap(\.attentionItems).map(\.id) + input.usageAlerts.map(\.id) + input.usageCovered)
    }
}

/// Durable storage for the notification ledger (`Store`; tests inject failures).
public protocol NotificationLedgerStore: Sendable {
    func loadNotificationLedger() throws -> [String: NotificationRecord]
    /// Inserts or replaces `records`, then removes records older than the retention period whose
    /// incident is not in `keepingOpen` (M4-R04: an open incident keeps its record).
    func writeNotificationRecords(_ records: [NotificationRecord], now: Date, keepingOpen: Set<String>) throws
}

/// Runs one planning and delivery step (SPEC §8) as a pending → submitted state machine.
///
/// 1. Plan against the in-memory copy of the durable ledger.
/// 2. Write the decisions durably. If that fails, nothing is sent and memory is unchanged, so the
///    next evaluation tries again (M4-R03).
/// 3. Claim each planned notification durably before submitting it: its attempt is counted and
///    timed first (M9 F2). A crash between submission and the result therefore leaves a counted
///    attempt, so the retry waits `retryAfter` and repeated crashes stop after `maxAttempts`.
/// 4. Before planning, a pending record with a counted attempt whose claimed notification
///    identifier Notification Center still holds (`alreadyShown`) was accepted before a crash: it
///    is marked `submitted` without submitting again (M9 F2). Only the incidents claimed under that
///    identifier are reconciled; an incident that opened since then is planned and delivered
///    normally (M9-E01).
/// 5. Submit; mark its incidents `submitted` only when macOS accepted it. A rejection keeps them
///    `pending` for a bounded retry (M4-R02).
/// One evaluation at a time: a call while another runs returns at once.
public actor NotificationDispatcher {
    public typealias Send = @Sendable (PlannedNotification) async -> Bool
    /// Identifiers of the notifications Notification Center holds for this app (nil: unknown).
    public typealias Shown = @Sendable () async -> Set<String>?
    public static let maxAttempts = 3
    public static let retryAfter: TimeInterval = 60

    public struct Report: Sendable, Equatable {
        public var submitted: [PlannedNotification] = []
        public var rejected: [PlannedNotification] = []
        public var recorded = 0
        public var suppressed = 0
        /// The ledger could not be read or written: nothing was sent.
        public var ledgerUnavailable = false
        /// A submitted notification could not be marked; after a restart it may be sent once more
        /// under the same identifier, which replaces the shown one.
        public var markFailed = false
        public var skippedBusy = false
        /// Retries whose identifier Notification Center already held: marked, not sent (M9 F2).
        public var alreadyShown: [String] = []
    }

    private let store: NotificationLedgerStore?
    private let send: Send
    private let shown: Shown?
    public private(set) var ledger: [String: NotificationRecord] = [:]
    private var loaded = false
    private var busy = false

    public init(store: NotificationLedgerStore?, send: @escaping Send, alreadyShown: Shown? = nil) {
        self.store = store
        self.send = send
        self.shown = alreadyShown
    }

    public func evaluate(_ input: NotificationPlanner.Input) async -> Report {
        var report = Report()
        guard !busy else {
            report.skippedBusy = true
            return report
        }
        busy = true
        defer { busy = false }
        guard let store else {
            report.ledgerUnavailable = true
            return report
        }
        if !loaded {
            guard let stored = try? store.loadNotificationLedger() else {
                report.ledgerUnavailable = true
                return report
            }
            ledger = stored
            loaded = true
        }
        let now = input.now
        let open = NotificationPlanner.openIncidents(input)
        // Reconcile attempts that may have been accepted before a crash (M9 F2, M9-E01).
        let inDoubt = ledger.values.filter { $0.state == .pending && $0.attempts > 0 && $0.notificationId != nil }
        if !inDoubt.isEmpty, let shown, let held = await shown() {
            let reconciled = inDoubt.filter { held.contains($0.notificationId!) }.map { record -> NotificationRecord in
                var record = record
                record.state = .submitted
                return record
            }
            if !reconciled.isEmpty {
                do {
                    try store.writeNotificationRecords(reconciled, now: now, keepingOpen: open)
                } catch {
                    report.ledgerUnavailable = true
                    return report
                }
                for record in reconciled { ledger[record.incident] = record }
                report.alreadyShown = reconciled.map(\.incident).sorted()
            }
        }
        let plan = NotificationPlanner.plan(input, ledger: ledger)
        guard !plan.record.isEmpty else { return report }
        do {
            try store.writeNotificationRecords(plan.record, now: now, keepingOpen: open)
        } catch {
            report.ledgerUnavailable = true
            return report
        }
        for record in plan.record { ledger[record.incident] = record }
        ledger = ledger.filter { $0.value.at >= now.addingTimeInterval(-Store.notificationRetention) || open.contains($0.key) }
        report.recorded = plan.record.count
        report.suppressed = plan.record.filter { $0.state == .suppressed }.count

        for planned in plan.deliver {
            // Claim: count and time the attempt durably before submitting (M9 F2).
            var claims: [NotificationRecord] = []
            for id in planned.incidents {
                guard var record = ledger[id] else { continue }
                record.attempts += 1
                record.lastAttemptAt = now
                record.notificationId = planned.id
                claims.append(record)
            }
            do {
                try store.writeNotificationRecords(claims, now: now, keepingOpen: open)
            } catch {
                report.ledgerUnavailable = true
                continue
            }
            for claim in claims { ledger[claim.incident] = claim }
            let accepted = await send(planned)
            var marks: [NotificationRecord] = []
            for id in planned.incidents {
                guard var record = ledger[id] else { continue }
                record.state = accepted ? .submitted : (record.attempts >= Self.maxAttempts ? .failed : .pending)
                ledger[id] = record
                marks.append(record)
            }
            if accepted { report.submitted.append(planned) } else { report.rejected.append(planned) }
            do {
                try store.writeNotificationRecords(marks, now: now, keepingOpen: open)
            } catch {
                report.markFailed = true
            }
        }
        return report
    }
}

extension Array {
    func partitioned(_ isIncluded: (Element) -> Bool) -> ([Element], [Element]) {
        var yes: [Element] = []
        var no: [Element] = []
        for element in self { if isIncluded(element) { yes.append(element) } else { no.append(element) } }
        return (yes, no)
    }
}
