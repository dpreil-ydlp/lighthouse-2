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
            MenuBarGlyph(stale: model.glyphStale, sourcesStale: model.allSourcesStale, usage: model.glyph,
                         showPercent: model.usageSettings.showWorstPercent, attention: model.attentionTotal)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// Menu bar icon (SPEC 2.7 §6.1): rest, near-limit arc (amber ≤ 20 % left, red ≤ 5 % left), optional
/// least-left text ("12% left"),
/// 40 % opacity when stale, and attention: filled glyph + count of open, unacknowledged items (no
/// animation). Marks combine; the VoiceOver label states all of them.
struct MenuBarGlyph: View {
    var stale: Bool
    var sourcesStale: Bool
    var usage: UsageGlyphState
    var showPercent: Bool
    var attention = 0

    var body: some View {
        HStack(spacing: 2) {
            Image(nsImage: LighthouseGlyph.image(nearLimit: usage.nearLimit, filled: attention > 0))
            if attention > 0 { Image(nsImage: LighthouseGlyph.count(attention)) }
            if showPercent, let left = usage.worstLeft {
                Text("\(Int(left.rounded()))% left").monospacedDigit()
            }
        }
        .opacity(stale ? 0.4 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private var label: String {
        var parts = [AppIdentity.name]
        if attention > 0 { parts.append("\(attention) item\(attention == 1 ? "" : "s") need attention") }
        if usage.nearLimit != .none, let worst = usage.worstDescription {
            parts.append("\(usage.nearLimit == .red ? "at limit" : "near limit"): \(worst)")
        }
        if sourcesStale { parts.append("sources stale") }
        if usage.allStale { parts.append("usage stale") }
        return parts.joined(separator: ", ")
    }
}

enum LighthouseGlyph {
    /// Template lighthouse outline, drawn so it tints with the menu bar.
    static let template: NSImage = make(arc: nil)
    static let amber: NSImage = make(arc: .systemOrange)
    static let red: NSImage = make(arc: .systemRed)
    static let filledTemplate: NSImage = make(arc: nil, filled: true)
    static let filledAmber: NSImage = make(arc: .systemOrange, filled: true)
    static let filledRed: NSImage = make(arc: .systemRed, filled: true)

    /// The attention count in red (owner request): drawn as a non-template image, since menu bar
    /// text is always tinted to the bar's color.
    @MainActor static func count(_ value: Int) -> NSImage {
        if let cached = counts[value] { return cached }
        let text = NSAttributedString(string: value > 99 ? "99+" : "\(value)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold),
            .foregroundColor: NSColor.systemRed,
        ])
        let size = text.size()
        let image = NSImage(size: NSSize(width: ceil(size.width), height: 18), flipped: false) { _ in
            text.draw(at: NSPoint(x: 0, y: (18 - size.height) / 2))
            return true
        }
        image.isTemplate = false
        counts[value] = image
        return image
    }
    @MainActor private static var counts: [Int: NSImage] = [:]

    static func image(nearLimit: NearLimit, filled: Bool = false) -> NSImage {
        switch nearLimit {
        case .none: filled ? filledTemplate : template
        case .amber: filled ? filledAmber : amber
        case .red: filled ? filledRed : red
        }
    }

    /// With an arc the image cannot be a template (the arc keeps its color), so the outline is drawn
    /// in `labelColor`, which resolves against the menu bar's appearance at draw time.
    private static func make(arc: NSColor?, filled: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let ink = arc == nil ? NSColor.black : NSColor.labelColor
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
            if filled { tower.fill() }
            let lamp = NSBezierPath(rect: NSRect(x: 7.6, y: 11.8, width: 2.8, height: 2.2))
            lamp.lineWidth = 1.1
            lamp.stroke()
            if filled { lamp.fill() }
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
            if let arc {
                arc.setStroke()
                let mark = NSBezierPath()
                mark.appendArc(withCenter: NSPoint(x: 9, y: 9.5), radius: 9, startAngle: 232, endAngle: 308)
                mark.lineWidth = 2
                mark.lineCapStyle = .round
                mark.stroke()
            }
            return true
        }
        image.isTemplate = arc == nil
        return image
    }
}
