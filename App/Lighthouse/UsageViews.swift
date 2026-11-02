import LighthouseCore
import SwiftUI

/// Usage block (SPEC 2.7 §6.2 item 2, CodexBar style). Figures and bars mean **left**.
struct UsageBlock: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let compact = model.appSettings.usageCompact
        VStack(alignment: .leading, spacing: compact ? 2 : 4) {
            HStack {
                // The header folds the block to one line per provider and back (saved).
                Button { withAnimation(.easeOut(duration: 0.15)) { model.toggleUsageCompact() } } label: {
                    HStack(spacing: 4) {
                        Text("USAGE").font(.system(size: 10, weight: .semibold)).tracking(0.8)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .rotationEffect(.degrees(compact ? 0 : 90))
                    }
                    .foregroundStyle(.tertiary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.usage.isEmpty)
                .help(compact ? "Show usage details" : "Compact usage")
                .accessibilityLabel(compact ? "Usage, compact. Show details" : "Usage, detailed. Compact")
                Spacer()
                if let checked = model.usage.compactMap(\.lastSuccessAt).min() {
                    Text("⟳ \(Age.short(checked, now: model.now)) ago")
                        .font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit()
                        .help("Oldest last successful usage check")
                }
            }
            if model.usage.isEmpty {
                SettingsLink {
                    HStack(spacing: 6) {
                        Text("Connect usage in Settings")
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else {
                ForEach(model.usage) { UsageRow(reading: $0, compact: compact) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Metrics.inset)
        .padding(.bottom, compact ? 6 : 10)
    }
}

enum UsageLayout {
    static let name: CGFloat = 92
    static let percent: CGFloat = 64
    static let reset: CGFloat = 96
}

/// One provider: line 1 session, line 2 week; or one reason line. The whole row pushes the provider page.
struct UsageRow: View {
    @Environment(AppModel.self) private var model
    let reading: ProviderUsage
    var compact = false
    @State private var hovering = false

    var body: some View {
        let focused = model.route == .home && model.focused == .provider(reading.provider)
        // One accessible button: VoiceOver reads the label (percent and freshness) and AXPress /
        // VoiceOver activation pushes the provider page (M2 gap: `.accessibilityElement(children:
        // .ignore)` replaced the button with a plain element that had no press action).
        Button { model.route = .provider(reading.provider) } label: {
            VStack(alignment: .leading, spacing: 3) {
                if compact { compactLine } else { lines }
            }
                .padding(.vertical, compact ? 2 : 4)
                .padding(.horizontal, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(focused ? Color.accentColor.opacity(0.12) : Color.primary.opacity(hovering ? 0.06 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -6)
        .onHover { hovering = $0 }
        .help("Open \(reading.provider.displayName) usage")
        .id(FocusOrder.Stop.provider(reading.provider))
        .accessibilityLabel(UsageWording.accessibility(reading, now: model.now))
        .accessibilityHint("Opens the \(reading.provider.displayName) usage page")
    }

    /// Compact: `Claude Max  ▬▬▬ 62%   week ▬▬ 80%`; no pace or reset (those stay in the tooltip,
    /// the detailed block and the provider page). Stale readings keep the grey bar.
    @ViewBuilder private var compactLine: some View {
        let windows = reading.displayWindows(now: model.now)
        let slots = [UsageWindow.sessionId, UsageWindow.weeklyId].map { id in windows.first { $0.id == id } }
        let shown = slots.compactMap { $0 }
        let stale = reading.status == .stale
        HStack(spacing: 8) {
            ProviderName(reading: reading)
            switch reading.status {
            case .signInRequired, .unavailable:
                Text(UsageWording.reason(reading)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            case .fresh, .stale:
                if shown.isEmpty {
                    Text(UsageWording.noWindows(reading, now: model.now)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                }
                // Two fixed columns (session, week) so rows line up; a missing window leaves its column empty.
                if !shown.isEmpty {
                    ForEach(Array(slots.enumerated()), id: \.offset) { _, window in
                        if let window { compactWindow(window, stale: stale) } else { Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                    }
                }
            }
        }
        .monospacedDigit()
    }

    private func compactWindow(_ window: UsageWindow, stale: Bool) -> some View {
        let pace = UsagePace(window: window, now: model.now)
        return HStack(spacing: 5) {
            if window.id == UsageWindow.weeklyId {
                Text("week").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            UsageBar(pace: pace, thick: false, stale: stale)
            Text("\(Int(pace.left.rounded()))%")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(stale ? Color.secondary : UsageTint.text(left: pace.left))
                .frame(width: 36, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
        .help(UsageWording.absoluteReset(window).map { "\(UsageText.windowName(window)) resets \($0)" } ?? "Reset time not reported")
    }

    @ViewBuilder private var lines: some View {
        let windows = reading.displayWindows(now: model.now)
        let session = windows.first { $0.id == UsageWindow.sessionId }
        let weekly = windows.first { $0.id == UsageWindow.weeklyId }
        switch reading.status {
        case .signInRequired, .unavailable:
            HStack(spacing: 8) {
                ProviderName(reading: reading)
                Text(UsageWording.reason(reading)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
        case .fresh, .stale:
            if session == nil && weekly == nil {
                HStack(spacing: 8) {
                    ProviderName(reading: reading)
                    Text(UsageWording.noWindows(reading, now: model.now)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                }
            } else {
                if let session {
                    WindowLine(window: session, stale: reading.status == .stale, thick: true) { ProviderName(reading: reading) }
                } else {
                    HStack { ProviderName(reading: reading); Spacer() }
                }
                if let weekly {
                    WindowLine(window: weekly, stale: reading.status == .stale, thick: false) {
                        Text("week").font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                if reading.status == .stale, let last = reading.lastSuccessAt {
                    Text("Stale · last success \(Age.short(last, now: model.now)) ago")
                        .font(.system(size: 11)).foregroundStyle(.orange).padding(.leading, UsageLayout.name + 8)
                }
            }
        }
    }
}

struct ProviderName: View {
    let reading: ProviderUsage
    var body: some View {
        HStack(spacing: 4) {
            Text(reading.provider.displayName).font(.system(size: 13, weight: .semibold))
            if let plan = UsageText.plan(reading.plan) { Text(plan).font(.system(size: 13)).foregroundStyle(.secondary) }
        }
        .lineLimit(1)
        .frame(width: UsageLayout.name, alignment: .leading)
    }
}

struct WindowLine<Label: View>: View {
    @Environment(AppModel.self) private var model
    let window: UsageWindow
    let stale: Bool
    let thick: Bool
    @ViewBuilder let label: () -> Label

    var body: some View {
        let pace = UsagePace(window: window, now: model.now)
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                label().frame(width: UsageLayout.name, alignment: .leading)
                UsageBar(pace: pace, thick: thick, stale: stale)
                Text(UsageText.left(pace))
                    .font(.system(size: thick ? 13 : 12, weight: thick ? .semibold : .regular))
                    .foregroundStyle(stale ? Color.secondary : UsageTint.text(left: pace.left))
                    .lineLimit(1)
                    .frame(width: UsageLayout.percent, alignment: .trailing)
                Text(UsageText.resetIn(pace) ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: UsageLayout.reset, alignment: .trailing)
            }
            PaceLine(pace: pace, stale: stale).padding(.leading, UsageLayout.name + 8)
        }
        .monospacedDigit()
        .help(UsageWording.absoluteReset(window).map { "Resets \($0)" } ?? "Reset time not reported")
    }
}

/// "2% in deficit · Runs out in 5d": reserve green, deficit orange, projection secondary.
struct PaceLine: View {
    let pace: UsagePace
    let stale: Bool

    var body: some View {
        if UsageText.paceLine(pace) != nil {
            let projection = UsageText.projection(pace)
            let paceText = UsageText.pace(pace)
            (Text(paceText ?? "").foregroundStyle(stale ? Color.secondary : UsageTint.pace(pace.delta))
                + Text(paceText != nil && projection != nil ? " · " : "").foregroundStyle(.tertiary)
                + Text(projection ?? "").foregroundStyle(.secondary))
                .font(.system(size: 11))
                .lineLimit(1)
        }
    }
}

/// Bar filled as **left**, with a tick where an even pace would leave the fill (CodexBar style).
/// The fill and marker come from `UsagePace` only (M6 C2 test).
struct UsageBar: View {
    let pace: UsagePace
    let thick: Bool
    var stale = false

    var fill: Double { pace.barFill }
    var marker: Double? { pace.marker }

    var body: some View {
        let height: CGFloat = thick ? 6 : 4
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12)).frame(height: height)
                if fill > 0 {
                    Capsule().fill(stale ? Color.secondary.opacity(0.6) : UsageTint.bar(left: pace.left))
                        .frame(width: max(height, geo.size.width * fill), height: height)
                }
                if let marker {
                    RoundedRectangle(cornerRadius: 0.75)
                        .fill(Color.primary.opacity(0.85))
                        .frame(width: 1.5, height: height + 4)
                        .offset(x: min(max(geo.size.width * marker - 0.75, 0), geo.size.width - 1.5))
                }
            }
            .frame(height: geo.size.height)
        }
        .frame(height: height + 4)
        .accessibilityHidden(true)
    }
}

enum UsageTint {
    static func bar(left: Double) -> Color {
        switch NearLimit.level(left: left) {
        case .red: .red
        case .amber: .orange
        case .none: Color.primary.opacity(0.72)
        }
    }

    static func text(left: Double) -> Color {
        switch NearLimit.level(left: left) {
        case .red: .red
        case .amber: .orange
        case .none: .primary
        }
    }

    static func pace(_ delta: Int?) -> Color {
        guard let delta else { return .secondary }
        return delta >= 1 ? .green : delta <= -1 ? .orange : .secondary
    }
}

enum UsageWording {
    static func signIn(_ provider: Provider) -> String {
        provider == .claude ? "Sign in again in Claude Code" : "Sign in again in Codex"
    }

    static func reason(_ reading: ProviderUsage) -> String {
        switch reading.status {
        case .signInRequired: signIn(reading.provider)
        case .unavailable(let reason): reason == "Checking…" ? reason : "Unavailable · \(reason)"
        case .fresh, .stale: ""
        }
    }

    static func noWindows(_ reading: ProviderUsage, now: Date) -> String {
        if let reset = reading.windows.compactMap(\.resetsAt).filter({ $0 <= now }).min() {
            return "Window reset \(Age.clock.string(from: reset)) · updating"
        }
        return "No usage windows reported"
    }

    /// Absolute reset for the tooltip and the provider page ("Thu 2:10 PM", SPEC 2.7 §6.2).
    static func absoluteReset(_ window: UsageWindow) -> String? {
        window.resetsAt.map { dayTime.string(from: $0) }
    }

    static let dayTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE h:mm a"
        return f
    }()

    /// VoiceOver: provider, plan, each window with percent left, pace, projection and reset, and freshness.
    static func accessibility(_ reading: ProviderUsage, now: Date) -> String {
        var parts = [[reading.provider.displayName, UsageText.plan(reading.plan)].compactMap { $0 }.joined(separator: " ")]
        switch reading.status {
        case .signInRequired, .unavailable:
            parts.append(reason(reading))
        case .fresh, .stale:
            for window in reading.displayWindows(now: now) where !window.isPool {
                parts.append("\(UsageText.windowName(window)) \(UsageText.spoken(UsagePace(window: window, now: now)))")
            }
            if let last = reading.lastSuccessAt {
                parts.append(reading.status == .stale ? "stale, last success \(Age.short(last, now: now)) ago" : "checked \(Age.short(last, now: now)) ago")
            }
        }
        return parts.joined(separator: ", ")
    }
}

/// Level 2 provider page (SPEC §6.3).
struct ProviderPage: View {
    @Environment(AppModel.self) private var model
    let provider: Provider

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let reading = model.usage(for: provider) {
                details(reading)
                Divider().opacity(0.5)
                projects(reading)
            } else {
                Text("\(provider.displayName) usage is off. Turn it on in Settings › Usage.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(Metrics.inset)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { model.pop() } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    Text("Back")
                }
            }
            .buttonStyle(.borderless)
            .help("Back (Esc)")
            Spacer()
            Text("\(provider.displayName) usage").font(.system(size: 14, weight: .semibold))
            Spacer()
            SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.borderless).help("Usage settings").accessibilityLabel("Usage settings")
        }
        .padding(.horizontal, Metrics.inset)
        .frame(height: 38)
    }

    private func details(_ reading: ProviderUsage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text([UsageText.plan(reading.plan).map { "\(provider.displayName) \($0)" }, reading.accountAlias].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                statusBadge(reading)
            }
            switch reading.status {
            case .signInRequired, .unavailable:
                Text(UsageWording.reason(reading)).font(.system(size: 12)).foregroundStyle(.secondary)
            case .fresh, .stale:
                let windows = reading.displayWindows(now: model.now)
                if windows.isEmpty {
                    Text(UsageWording.noWindows(reading, now: model.now)).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(windows) { window in
                    let pace = UsagePace(window: window, now: model.now)
                    let stale = reading.status == .stale
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(window.isPool ? window.label : UsageText.windowName(window).capitalized).font(.system(size: 12))
                            Spacer()
                            Text(UsageText.left(pace))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(stale ? Color.secondary : UsageTint.text(left: pace.left))
                        }
                        UsageBar(pace: pace, thick: !window.isPool, stale: stale)
                        PaceLine(pace: pace, stale: stale)
                        if let reset = UsageWording.absoluteReset(window), let relative = pace.resetIn {
                            Text("Resets \(reset) · in \(UsageText.duration(relative))")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(window.isPool ? window.label : UsageText.windowName(window)) \(UsageText.spoken(pace))")
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                row("Last success", reading.lastSuccessAt.map { Age.stamp($0, now: model.now) } ?? "None yet")
                row("Last attempt", reading.lastAttemptAt.map { Age.stamp($0, now: model.now) } ?? "Not yet")
                row("Source", reading.source)
            }
            .font(.system(size: 11))
            .padding(.top, 2)
        }
        .monospacedDigit()
        .padding(.horizontal, Metrics.inset)
        .padding(.bottom, 10)
    }

    @ViewBuilder private func statusBadge(_ reading: ProviderUsage) -> some View {
        switch reading.status {
        case .fresh: Text("Fresh").font(.system(size: 11)).foregroundStyle(.green)
        case .stale: Text("Stale").font(.system(size: 11)).foregroundStyle(.orange)
        case .signInRequired: Text("Sign-in required").font(.system(size: 11)).foregroundStyle(.orange)
        case .unavailable: Text("Unavailable").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).lineLimit(1).truncationMode(.middle)
        }
    }

    private func projects(_ reading: ProviderUsage) -> some View {
        let attribution = model.attribution(for: provider)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("PROJECTS THIS WINDOW")
                    .font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(.tertiary)
                if attribution.partial {
                    Text("Partial").font(.system(size: 11)).foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, Metrics.inset).padding(.top, 10).padding(.bottom, 4)
            if attribution.projects.isEmpty {
                Text("No activity this window")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.horizontal, Metrics.inset).padding(.vertical, 6)
            } else {
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(attribution.projects.enumerated()), id: \.element.id) { index, entry in
                            Button { model.openProject(entry.project.identity.root, from: provider) } label: {
                                HStack(spacing: 8) {
                                    Text(entry.project.identity.name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 6)
                                    Text(TokenWording.projectFigure(tokens: entry.tokens)).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, Metrics.inset).padding(.vertical, 5)
                            .background(model.providerFocus == index ? Color.accentColor.opacity(0.12) : .clear)
                            .id("provider-row-\(index)")
                            .help(TokenWording.projectHelp(tokens: entry.tokens))
                            .accessibilityLabel(TokenWording.projectAccessibility(name: entry.project.identity.name, tokens: entry.tokens))
                        }
                    }
                    .padding(.bottom, 6)
                }
                .panelScroll(model)
                .onChange(of: model.providerFocus) { _, index in
                    if let index { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo("provider-row-\(index)", anchor: nil) } }
                }
                }
            }
        }
    }
}

/// Every local-token figure is approximate (whole 5-minute intervals, SPEC 2.5 §5.5); each wording
/// says so, including the VoiceOver labels.
enum TokenWording {
    static func projectFigure(tokens: Int) -> String { "≈ " + TokenFormat.short(tokens) }
    static func projectHelp(tokens: Int) -> String { "Approximately \(tokens.formatted()) local tokens" }
    static func projectAccessibility(name: String, tokens: Int) -> String {
        "\(name), approximately \(tokens.formatted()) local tokens this window, not quota share"
    }
    static func threadDetail(window: Int, session: Int, partial: Bool) -> String {
        "approximately \(window.formatted()) this window (whole 5-min intervals) · \(session.formatted()) session"
            + (partial ? " · partial" : "") + " · not quota share"
    }
}

enum TokenFormat {
    /// "950", "12.4 K", "3.1 M".
    static func short(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        if n < 1_000_000 { return String(format: "%.1f K", Double(n) / 1000) }
        return String(format: "%.1f M", Double(n) / 1_000_000)
    }
}
