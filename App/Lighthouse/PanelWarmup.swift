import AppKit

/// Creates the MenuBarExtra panel window once at launch, invisibly, so the user's first click
/// reuses a built window (SPEC §3.2: panel opens in < 150 ms). The very first open of a window
/// that was never built is much slower than later opens.
///
/// The warm-up presses the app's own status item button twice in one run-loop turn with the new
/// window fully transparent, then restores the previously active app. It touches no other app.
@MainActor
enum PanelWarmup {
    private(set) static var isWarming = false

    /// Runs once the status item exists (retries for up to 2 s after launch).
    static func run(attempt: Int = 0) {
        guard let button = statusButton() else {
            if attempt < 40 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { run(attempt: attempt + 1) }
            } else {
                log.error("warmup skipped: status button not found")
            }
            return
        }
        // The owner opened the panel first: the window is built, and it must not be touched.
        if NSApp.windows.contains(where: { isPanel($0) && $0.isVisible }) {
            log.notice("warmup not needed: panel already open")
            return
        }
        let previous = NSWorkspace.shared.frontmostApplication
        let visibleBefore = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        // Windows this click made visible, whatever their size so far: the panel may
        // not be laid out at 400 pt yet when the click returns, so a size test can miss it.
        func opened() -> [NSWindow] {
            NSApp.windows.filter { $0.isVisible && !visibleBefore.contains(ObjectIdentifier($0)) && !isStatusBar($0) }
        }
        isWarming = true
        button.performClick(nil)
        var hidden = opened()
        for window in hidden { window.alphaValue = 0 }
        DispatchQueue.main.async {
            // The window may appear one turn later; hide it before it is drawn, then close it.
            for window in opened() where !hidden.contains(where: { $0 === window }) {
                window.alphaValue = 0
                hidden.append(window)
            }
            if hidden.contains(where: \.isVisible) { button.performClick(nil) }
            DispatchQueue.main.async {
                for window in hidden { window.alphaValue = 1 }
                isWarming = false
                if let previous, previous != NSRunningApplication.current { previous.activate() }
                log.notice("warmup done hidden=\(hidden.count, privacy: .public) stillVisible=\(hidden.filter(\.isVisible).count, privacy: .public)")
            }
        }
    }

    private static func isStatusBar(_ window: NSWindow) -> Bool {
        String(describing: type(of: window)).contains("StatusBar")
    }

    static func isPanel(_ window: NSWindow) -> Bool {
        let name = String(describing: type(of: window))
        return !name.contains("StatusBar") && window.frame.width >= 380 && window.frame.width <= 420
    }

    static func statusButton() -> NSStatusBarButton? {
        for window in NSApp.windows where String(describing: type(of: window)).contains("StatusBar") {
            if let button = find(in: window.contentView) { return button }
        }
        return nil
    }

    private static func find(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for sub in view.subviews { if let found = find(in: sub) { return found } }
        return nil
    }
}
