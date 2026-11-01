import LighthouseCore
import SwiftUI

enum Metrics {
    static let width: CGFloat = 400
    static let inset: CGFloat = 14
    static var maxHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 900
        return min(720, screen - 80)
    }
}

/// Level 1 panel (SPEC §6.2): header, usage block, search, shelf, footer.
struct PanelView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            switch model.route {
            case .home:
                header
                UsageBlock()
                if !model.appSettings.onboarded {
                    Divider().opacity(0.5)
                    OnboardingView()
                } else {
                    AttentionStrip()
                    if model.searchVisible { searchField }
                    Divider().opacity(0.5)
                    shelfScroll
                }
            case .project(let root):
                ProjectPage(root: root)
            case .provider(let provider):
                ProviderPage(provider: provider)
            }
            Divider().opacity(0.5)
            FooterView()
        }
        .frame(width: Metrics.width)
        // M4-R09: report the page's own height; `PanelControl.fit` sizes the window to it,
        // top-anchored, so a shorter page never leaves a transparent gap.
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.panelContentHeight = $0 }
        .overlay(alignment: .bottom) { ToastView() }
        // Keys (SPEC §9) arrive through `AppModel.handleKey` (a local monitor on this window).
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(AppIdentity.name).font(.system(size: 15, weight: .semibold))
            Spacer()
            Button { if model.searchVisible { model.escape() } else { model.openSearch("") } } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Search projects and threads (⌘F)")
            .accessibilityLabel("Search")
            SettingsLink { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .keyboardShortcut(",", modifiers: .command)
                .help("Settings (⌘,)")
                .accessibilityLabel("Settings")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, Metrics.inset)
        .frame(height: 32)
        .padding(.top, 6)
    }

    private var searchField: some View {
        @Bindable var model = model
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
            TextField("Find a project or thread", text: $model.searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onChange(of: model.searchText) { _, _ in model.searchFocus = nil }
                .accessibilityLabel("Search projects and threads")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, Metrics.inset)
        .padding(.bottom, 8)
        .onAppear { focusSearch() }
        .onChange(of: model.searchFocusRequest) { _, _ in focusSearch() }
    }

    /// Focus the field with the caret after any typed character (focus alone selects all text,
    /// and the next key would replace the first).
    private func focusSearch() {
        searchFocused = true
        DispatchQueue.main.async {
            (NSApp.keyWindow?.firstResponder as? NSTextView)?.moveToEndOfDocument(nil)
        }
    }

    private var shelfScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Group {
                    if model.searchVisible && !model.searchText.isEmpty {
                        SearchResults()
                    } else {
                        ShelfView()
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            // Grow to content, then scroll (SPEC §6: max = min(720, screen − 80) for the whole panel).
            .panelScroll(model)
            .onChange(of: model.focused) { _, stop in
                if let stop { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(stop, anchor: nil) } }
            }
            .onChange(of: model.searchFocus) { _, index in
                if let index { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo("hit-\(index)", anchor: nil) } }
            }
        }
    }
}

struct FooterView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            if let checked = model.snapshot.checkedAt {
                Text("Checked \(Age.short(checked, now: model.now)) ago")
            } else {
                Text("Reading sessions…")
            }
            if let note = model.coverageNote {
                Text("·")
                Text(note).foregroundStyle(.orange.opacity(0.9))
            }
            if model.snapshot.statuses.contains(where: { $0.error != nil }) || model.storeError != nil {
                Text("·")
                SettingsLink { Text("Source issue") }.buttonStyle(.plain).foregroundStyle(.orange)
            }
            Spacer()
            // Pause alerts: Lighthouse notifications only; detection continues (SPEC §6.2 item 6, §8).
            Button(model.appSettings.alertsPaused ? "Alerts paused" : "Pause alerts") {
                model.setAlertsPaused(!model.appSettings.alertsPaused)
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.appSettings.alertsPaused ? Color.orange : Color.secondary)
            .help(model.appSettings.alertsPaused ? "Resume Lighthouse notifications" : "Pause Lighthouse notifications; attention is still shown here")
            .accessibilityLabel(model.appSettings.alertsPaused ? "Alerts paused. Resume alerts" : "Pause alerts")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .padding(.horizontal, Metrics.inset)
        .frame(height: 26)
    }
}

struct ToastView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let toast = model.toast {
            Text(toast)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.separator))
                .padding(.bottom, 34)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityAddTraits(.updatesFrequently)
        }
    }
}

enum Age {
    /// "20 s", "3 m", "2 h", "4 d".
    static func short(_ date: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) m" }
        if s < 86400 { return "\(s / 3600) h" }
        return "\(s / 86400) d"
    }

    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    static let dayClock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        return f
    }()

    static func stamp(_ date: Date, now: Date) -> String {
        let formatter = Calendar.current.isDate(date, inSameDayAs: now) ? clock : dayClock
        return "\(formatter.string(from: date)) · \(short(date, now: now)) ago"
    }
}
