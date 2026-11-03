import AppKit
import Carbon.HIToolbox
import LighthouseCore
import ServiceManagement
import SwiftUI
import UserNotifications

extension View {
    /// A page's scroll area: as tall as its content, at most `AppModel.scrollCap`, so the whole page
    /// stays within the SPEC maximum (M4-R09; a fixed "max − 160" cap could let a page with search open
    /// grow past the maximum). Reports its height for the cap.
    @MainActor func panelScroll(_ model: AppModel) -> some View {
        frame(maxHeight: model.scrollCap)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.scrollHeight = $0 }
    }
}

/// Closes the panel and opens Settings in front. `SettingsLink` alone opened the window behind the
/// frontmost app (a menu bar app is not brought forward), and the open panel covered it.
struct SettingsButton<Label: View>: View {
    @Environment(\.openSettings) private var openSettings
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button { SettingsWindow.open(openSettings) } label: { label() }
    }
}

@MainActor
enum SettingsWindow {
    static func open(_ openSettings: OpenSettingsAction) {
        PanelControl.close()
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
        // The window exists only after this run loop turn.
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: isSettings) else {
                log.error("settings: window not found")
                return
            }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            log.notice("settings front key=\(window.isKeyWindow, privacy: .public) active=\(NSApp.isActive, privacy: .public)")
        }
    }

    static func isSettings(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true
            || (window.styleMask.contains(.titled) && !PanelWarmup.isPanel(window) && window.isVisible)
    }
}

/// Opens and closes the MenuBarExtra panel through the app's own status item, the same path as a
/// click, so `PanelVisibility` and the frozen shelf behave identically.
@MainActor
enum PanelControl {
    static var isOpen: Bool {
        NSApp.windows.contains { PanelWarmup.isPanel($0) && $0.isVisible && $0.alphaValue > 0 }
    }

    /// A click on the status item activates the app; `performClick` alone does not, so the panel
    /// would open without keyboard focus and keys would go to the app in front. Activate first,
    /// then make the panel the key window.
    static func toggle() {
        guard let button = PanelWarmup.statusButton() else {
            log.error("panel toggle: status button not found")
            return
        }
        let opening = !isOpen
        if opening { NSApp.activate(ignoringOtherApps: true) }
        button.performClick(nil)
        guard opening else { return }
        DispatchQueue.main.async {
            guard let panel = NSApp.windows.first(where: { PanelWarmup.isPanel($0) && $0.isVisible }) else { return }
            panel.makeKey()
            log.notice("panel key=\(panel.isKeyWindow, privacy: .public) active=\(NSApp.isActive, privacy: .public)")
        }
    }

    static func open() { if !isOpen { toggle() } }

    /// Sizes the visible panel to `contentHeight` (capped at the SPEC maximum), keeping its top edge
    /// under the status item (M4-R09). MenuBarExtra alone did not always shrink the window when a
    /// page got shorter, leaving a tall frame around a short page.
    static func fit(contentHeight: CGFloat) {
        guard contentHeight > 0,
              let panel = NSApp.windows.first(where: { PanelWarmup.isPanel($0) && $0.isVisible && $0.alphaValue > 0 }) else { return }
        let chrome = panel.frame.height - panel.contentLayoutRect.height
        guard let frame = PanelFrame.fitted(panel.frame, contentHeight: contentHeight + chrome, maxHeight: Metrics.maxHeight) else { return }
        log.notice("panel fit content=\(Int(contentHeight.rounded()), privacy: .public) from=\(Int(panel.frame.height), privacy: .public) to=\(Int(frame.height), privacy: .public) top=\(Int(frame.maxY), privacy: .public)")
        panel.setFrame(frame, display: true)
    }
    static func close() { if isOpen { toggle() } }
}

/// Lighthouse notifications through `UNUserNotificationCenter` (SPEC §8). Opt-in; standard
/// interruption level, so macOS Focus decides what is shown. No action buttons: a click only opens
/// the panel at the relevant page (V-OBS).
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// `UNUserNotificationCenter` needs an app bundle; the SwiftPM executable has none.
    static var available: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }

    private let center: UNUserNotificationCenter?
    var onOpen: (_ projectRoot: String?, _ provider: Provider?) -> Void = { _, _ in }
    private(set) var status: UNAuthorizationStatus = .notDetermined
    /// False until the system has answered the first status query of this run.
    private(set) var statusKnown = false
    var isAuthorized: Bool { [.authorized, .provisional].contains(status) }

    override init() {
        center = Self.available ? UNUserNotificationCenter.current() : nil
        super.init()
        center?.delegate = self
    }

    func refreshStatus() async {
        guard let center else {
            statusKnown = true
            return
        }
        status = await center.notificationSettings().authorizationStatus
        statusKnown = true
    }

    /// Shows the system permission prompt the first time; returns whether alerts are allowed.
    func requestAuthorization() async -> Bool {
        guard let center else { return false }
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        await refreshStatus()
        log.notice("notification authorization granted=\(granted, privacy: .public)")
        return granted
    }

    /// Submits one notification; true only when macOS accepted it (M4-R02).
    func submit(_ planned: PlannedNotification) async -> Bool {
        guard let center else { return false }
        let content = UNMutableNotificationContent()
        content.title = planned.title
        content.body = planned.body
        content.threadIdentifier = planned.projectRoot ?? planned.provider?.rawValue ?? "lighthouse"
        content.interruptionLevel = .active
        if planned.category == .waiting { content.sound = .default }
        var info: [String: String] = [:]
        if let root = planned.projectRoot { info["project"] = root }
        if let provider = planned.provider { info["provider"] = provider.rawValue }
        content.userInfo = info
        let request = UNNotificationRequest(identifier: planned.id, content: content, trigger: nil)
        let category = planned.category.rawValue, count = planned.incidents.count
        do {
            try await center.add(request)
        } catch {
            log.error("notification not added category=\(category, privacy: .public) error=\((error as NSError).code, privacy: .public)")
            return false
        }
        // The identifier is an incident identity (ids and a time; no title or text).
        log.notice("notification delivered category=\(category, privacy: .public) incidents=\(count, privacy: .public) id=\(planned.id, privacy: .public)")
        await logHeld()
        return true
    }

    /// The identifiers Notification Center holds for Lighthouse (incident identities: ids and a
    /// time, no titles or text), for receipt evidence.
    func logHeld() async {
        guard let center else { return }
        let ids = await center.deliveredNotifications().map(\.request.identifier).sorted()
        log.notice("notification center holds \(ids.count, privacy: .public) Lighthouse notifications ids=\(ids.joined(separator: ","), privacy: .public)")
    }

    /// Identifiers Notification Center holds for Lighthouse; nil without a notification center.
    /// Lets a retry after a crash see that macOS already accepted it (M9 F2).
    func shownIdentifiers() async -> Set<String>? {
        guard let center else { return nil }
        return Set(await center.deliveredNotifications().map(\.request.identifier))
    }

    /// Count of Lighthouse notifications in Notification Center (receipt evidence).
    func deliveredCount() async -> Int {
        guard let center else { return 0 }
        return await center.deliveredNotifications().count
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let root = info["project"] as? String
        let provider = (info["provider"] as? String).flatMap(Provider.init(rawValue:))
        await MainActor.run {
            log.notice("notification clicked")
            self.onOpen(root, provider)
        }
    }
}

/// The global hotkey (SPEC §9; default ⌃⌥Space, see `HotkeyChoice`). Carbon hot keys need no Accessibility
/// permission and swallow only their own key combination.
@MainActor
final class Hotkey {
    static let shared = Hotkey()
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var action: () -> Void = {}

    /// Registers `choice`, replacing any earlier one. Returns the Carbon status (0 = registered).
    @discardableResult
    func register(_ choice: HotkeyChoice) -> OSStatus {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        installHandler()
        guard let (key, modifiers) = Self.combination(choice) else {
            log.notice("hotkey off")
            return noErr
        }
        let id = EventHotKeyID(signature: OSType(0x4C48_3220), id: 1)   // "LH2 "
        let status = RegisterEventHotKey(key, modifiers, id, GetApplicationEventTarget(), 0, &ref)
        log.notice("hotkey register \(choice.label, privacy: .public) status=\(status, privacy: .public)")
        return status
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { Hotkey.shared.fire() } }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    private func fire() {
        log.notice("hotkey pressed")
        action()
    }

    /// ChatGPT's desktop app opens its companion window on ⌥Space by default and does not give the
    /// key up, so both apps react. Settings and onboarding say so.
    static var chatGPTInstalled: Bool {
        ["com.openai.chat", "com.openai.codex"].contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    }

    static func combination(_ choice: HotkeyChoice) -> (UInt32, UInt32)? {
        switch choice {
        case .off: nil
        case .optionSpace: (UInt32(kVK_Space), UInt32(optionKey))
        case .controlOptionSpace: (UInt32(kVK_Space), UInt32(optionKey | controlKey))
        case .commandShiftL: (UInt32(kVK_ANSI_L), UInt32(cmdKey | shiftKey))
        }
    }
}

/// Open at login through `SMAppService.mainApp` (SPEC §3, §6.6).
@MainActor
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }
    static var isOn: Bool { status == .enabled || status == .requiresApproval }

    /// Set when the last register or unregister call failed; Settings then points to System Settings.
    private(set) static var lastChangeFailed = false

    static var statusText: String { text(for: status) }

    /// `.notFound` is what macOS reports for the main app before its first registration (an installed
    /// copy that was never registered), so it reads as Off; a failed change is shown separately.
    nonisolated static func text(for status: SMAppService.Status) -> String {
        switch status {
        case .enabled: "On"
        case .requiresApproval: "Needs approval in System Settings"
        case .notRegistered, .notFound: "Off"
        @unknown default: "Unknown"
        }
    }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            lastChangeFailed = false
        } catch {
            lastChangeFailed = true
            log.error("login item change failed on=\(on, privacy: .public) code=\((error as NSError).code, privacy: .public)")
        }
        log.notice("login item status=\(statusText, privacy: .public)")
    }
}
