import AppKit
import LighthouseCore
import SwiftUI

/// Receipt screenshots without Screen Recording permission: when launched with
/// `-LighthouseSnapshot <name>` (launch arguments only, never saved defaults), the app renders its own
/// open panel to PNG files in the fixed folder `SnapshotFolder.path`. All writes go through
/// `SnapshotFolder.write`, which refuses symlinks (M2-01).
enum ReceiptSnapshot {
    static let name: String? = SnapshotFolder.name(arguments: CommandLine.arguments)

    @MainActor static func captureSoon(model: AppModel) {
        guard name != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            capture()
            render(model: model)
            if CommandLine.arguments.contains("-LighthouseSnapshotSummarySettings") { captureSummarySettings(model: model) }
        }
    }

    /// Settings › Summaries in its own window, rendered from its layer tree (M8 C4). Snapshot mode
    /// only; the window closes after the capture.
    @MainActor private static func captureSummarySettings(model: AppModel) {
        guard let name else { return }
        let host = NSHostingView(rootView: SummarySettingsView().environment(model).frame(width: 520, height: 470))
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 520, height: 470), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Summaries"
        window.contentView = host
        window.appearance = NSApp.appearance
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            write(window, file: "\(name)-summary-settings.png")
            window.orderOut(nil)
        }
    }

    /// SwiftUI's own offscreen render of the same views with the live model. It draws shapes (bars,
    /// tints) that the window layer render omits; AppKit-backed pieces (scroll views) may be blank.
    @MainActor private static func render(model: AppModel) {
        guard let name else { return }
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let wrote = renderPanel(model: model, file: "\(name)-swiftui.png")
        let wroteGlyphs = renderGlyphs(dark: dark)
        if wrote && wroteGlyphs { log.notice("receipt render written") } else { log.notice("receipt render refused") }
    }

    /// The panel's current page through SwiftUI's renderer, without scroll views (which it leaves
    /// blank), on the window background of the current appearance.
    @MainActor private static func renderPanel(model: AppModel, file: String) -> Bool {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let content = VStack(alignment: .leading, spacing: 0) {
            switch model.route {
            case .provider(let provider): ProviderPage(provider: provider)
            case .project(let root): ProjectPage(root: root)
            case .home:
                UsageBlock().padding(.top, 8)
                if model.appSettings.onboarded {
                    AttentionStrip()
                    if model.searchVisible && !model.searchText.isEmpty { SearchResults() } else { ShelfView() }
                } else {
                    OnboardingView()
                }
            }
            Divider().opacity(0.5)
            FooterView()
        }
        .environment(model)
        .environment(\.receiptFlat, true)
        .frame(width: Metrics.width)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return false }
        return SnapshotFolder.write(png, file: file)
    }

    /// The production menu bar glyph in each §6.1 state (synthetic states, for the visual check only).
    @MainActor private static func renderGlyphs(dark: Bool) -> Bool {
        let states: [(String, MenuBarGlyph)] = [
            ("rest", MenuBarGlyph(stale: false, sourcesStale: false, usage: UsageGlyphState(nearLimit: .none, worstPercent: 41, worstDescription: nil, allStale: false), showPercent: false)),
            ("≤ 20% left", MenuBarGlyph(stale: false, sourcesStale: false, usage: UsageGlyphState(nearLimit: .amber, worstPercent: 88, worstDescription: nil, allStale: false), showPercent: false)),
            ("≤ 5% left", MenuBarGlyph(stale: false, sourcesStale: false, usage: UsageGlyphState(nearLimit: .red, worstPercent: 97, worstDescription: nil, allStale: false), showPercent: false)),
            ("+ least left", MenuBarGlyph(stale: false, sourcesStale: false, usage: UsageGlyphState(nearLimit: .amber, worstPercent: 88, worstDescription: nil, allStale: false), showPercent: true)),
            ("stale", MenuBarGlyph(stale: true, sourcesStale: false, usage: UsageGlyphState(nearLimit: .none, worstPercent: nil, worstDescription: nil, allStale: true), showPercent: false)),
            ("attention 2", MenuBarGlyph(stale: false, sourcesStale: false, usage: UsageGlyphState(nearLimit: .none, worstPercent: 41, worstDescription: nil, allStale: false), showPercent: false, attention: 2)),
        ]
        let strip = HStack(spacing: 18) {
            ForEach(states, id: \.0) { label, glyph in
                VStack(spacing: 4) {
                    glyph.font(.system(size: 13)).frame(height: 22)
                    Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: strip)
        renderer.scale = 3
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return false }
        return SnapshotFolder.write(png, file: "menu-bar-glyph-states.png")
    }

    @MainActor private static func capture() {
        guard let name else { return }
        for window in NSApp.windows where window.isVisible && window.frame.width == 400 {
            write(window, file: "\(name).png")
        }
    }

    @MainActor private static var step = 0

    /// Snapshot mode only: F5 in the panel writes `<name>-NN.png` of the panel as it is now (keyboard
    /// walk evidence). Without `-LighthouseSnapshot` the key does nothing.
    @MainActor static func captureStep() -> Bool {
        guard let name else { return false }
        step += 1
        for window in NSApp.windows where window.isVisible && PanelWarmup.isPanel(window) {
            write(window, file: String(format: "%@-%02d.png", name, step))
        }
        if let model = AppModel.current { _ = renderPanel(model: model, file: String(format: "%@-%02d-swiftui.png", name, step)) }
        log.notice("receipt step \(step, privacy: .public) written")
        return true
    }

    /// Renders the window's layer tree (shapes, text and images) into a bitmap at the screen's scale.
    @MainActor private static func write(_ window: NSWindow, file: String) {
        guard let view = window.contentView?.superview ?? window.contentView, let layer = view.layer else { return }
        let scale = window.backingScaleFactor
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else { return }
        context.scaleBy(x: scale, y: scale)
        // The panel's material is not in the layer tree: paint the window background of the
        // window's own appearance first, so light and dark captures read as they do on screen.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: size).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        if !layer.isGeometryFlipped && !view.isFlipped {
            // Layer coordinates already match Core Graphics (origin bottom left).
        } else {
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
        }
        layer.render(in: context)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        if SnapshotFolder.write(png, file: file) { log.notice("receipt snapshot written") } else { log.notice("receipt snapshot refused") }
    }
}
