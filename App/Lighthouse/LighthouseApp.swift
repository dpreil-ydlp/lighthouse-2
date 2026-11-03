import LighthouseCore
import SwiftUI

/// The name and version the app shows (panel header, menu bar label, welcome, Settings › General).
/// The bundle file is `Lighthouse 2.app`; the id stays `com.lighthouse.v2`, so permissions and the
/// settings keyed to the id carry over.
enum AppIdentity {
    static let name = "Lighthouse 2"

    static func versionLine(info: [String: Any]? = Bundle.main.infoDictionary) -> String {
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(name) \(version) (\(build))"
    }
}

@main
struct LighthouseApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environment(model)
        } label: {
            MenuBarGlyph(usage: model.glyph, showPercent: model.usageSettings.showWorstPercent,
                         needsYou: model.attentionCounts[.needsYou] ?? 0)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// Menu bar icon (SPEC §6.1, owner 2026-11-03): the lighthouse, and when something waits for the
/// owner, the count in red right after it. Nothing else changes the icon (no usage arcs, no stale
/// dimming, no fill). The optional least-left text stays a Settings choice, off by default.
///
/// The logo and the count are one image: a menu bar label shows a single image (plus text), so a
/// second image was silently dropped (0.0.7–0.0.10 showed no count, or no logo).
struct MenuBarGlyph: View {
    var usage: UsageGlyphState
    var showPercent: Bool
    /// Threads and subagents waiting for the owner.
    var needsYou = 0

    var body: some View {
        HStack(spacing: 2) {
            Image(nsImage: LighthouseGlyph.image(count: needsYou))
            if showPercent, let left = usage.worstLeft {
                Text("\(Int(left.rounded()))% left").monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(needsYou > 0 ? "\(AppIdentity.name), \(needsYou) waiting for you" : AppIdentity.name)
    }
}

@MainActor
enum LighthouseGlyph {
    /// The plain logo: a template image, so it tints with the menu bar.
    static let plain: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            drawLogo(ink: .black)
            return true
        }
        image.isTemplate = true
        return image
    }()

    /// The logo, then the count in red. Not a template (the red must stay red), so the logo is drawn
    /// in `labelColor`, which resolves against the menu bar's appearance when the image is drawn.
    static func image(count: Int) -> NSImage {
        guard count > 0 else { return plain }
        if let cached = counted[count] { return cached }
        let text = NSAttributedString(string: count > 99 ? "99+" : "\(count)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold),
            .foregroundColor: NSColor.systemRed,
        ])
        let size = text.size()
        let image = NSImage(size: NSSize(width: 20 + ceil(size.width), height: 18), flipped: false) { _ in
            drawLogo(ink: .labelColor)
            text.draw(at: NSPoint(x: 20, y: (18 - size.height) / 2))
            return true
        }
        image.isTemplate = false
        counted[count] = image
        return image
    }
    private static var counted: [Int: NSImage] = [:]

    private static func drawLogo(ink: NSColor) {
        ink.setStroke()
        ink.setFill()
        let tower = NSBezierPath()
        tower.move(to: NSPoint(x: 6.2, y: 2.5))
        tower.line(to: NSPoint(x: 7.4, y: 11))
        tower.line(to: NSPoint(x: 10.6, y: 11))
        tower.line(to: NSPoint(x: 11.8, y: 2.5))
        tower.close()
        tower.lineWidth = 1.3
        tower.stroke()
        let lamp = NSBezierPath(rect: NSRect(x: 7.6, y: 11.8, width: 2.8, height: 2.2))
        lamp.lineWidth = 1.1
        lamp.stroke()
        let cap = NSBezierPath()
        cap.move(to: NSPoint(x: 7.1, y: 14.4))
        cap.line(to: NSPoint(x: 9, y: 16.2))
        cap.line(to: NSPoint(x: 10.9, y: 14.4))
        cap.close()
        cap.fill()
        let base = NSBezierPath()
        base.move(to: NSPoint(x: 4, y: 2.5))
        base.line(to: NSPoint(x: 14, y: 2.5))
        base.lineWidth = 1.3
        base.stroke()
        for (from, to) in [(NSPoint(x: 11.4, y: 13), NSPoint(x: 15.6, y: 14.4)), (NSPoint(x: 6.6, y: 13), NSPoint(x: 2.4, y: 14.4))] {
            let beam = NSBezierPath()
            beam.move(to: from)
            beam.line(to: to)
            beam.lineWidth = 1
            beam.stroke()
        }
    }
}
