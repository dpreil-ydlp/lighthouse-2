import AppKit

/// Reports each real show and hide of the MenuBarExtra panel window (M1-06). SwiftUI keeps the
/// panel's content view alive, so `onAppear` fires only once; window notifications fire every time.
/// The invisible warm-up show (alpha 0, `PanelWarmup.isWarming`) is reported as a warm-up.
/// Lives for the app's lifetime; AppKit posts these notifications on the main thread.
@MainActor
final class PanelVisibility: NSObject {
    private let onChange: @MainActor (_ visible: Bool, _ warmup: Bool) -> Void
    private var lastVisible = false

    init(onChange: @escaping @MainActor (_ visible: Bool, _ warmup: Bool) -> Void) {
        self.onChange = onChange
        super.init()
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didChangeOcclusionStateNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowChanged(_:)), name: name, object: nil)
        }
    }

    @objc private func windowChanged(_ note: Notification) {
        guard let window = note.object as? NSWindow, PanelWarmup.isPanel(window) else { return }
        let warmup = PanelWarmup.isWarming || window.alphaValue == 0
        let visible = window.isVisible && window.occlusionState.contains(.visible)
        if warmup {
            onChange(visible, true)
            return
        }
        guard visible != lastVisible else { return }
        lastVisible = visible
        onChange(visible, false)
    }
}
