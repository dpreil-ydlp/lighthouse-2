// Draws the Lighthouse app icon (an original mark: the menu bar glyph's tower, lamp and beams on a
// night tile) into App/Lighthouse/Assets.xcassets/AppIcon.appiconset. Headless CoreGraphics only.
// Usage: swift scripts/make-icon.swift [appiconset-folder]
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let folder = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "App/Lighthouse/Assets.xcassets/AppIcon.appiconset"

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// One icon at `pixels` square. Coordinates are in a 18-unit box (the menu bar glyph's grid, y up),
/// mapped onto the tile. Small sizes use a tighter tile margin and a wider tower so the mark still
/// reads at 16 px.
func render(pixels: Int) -> CGImage {
    let size = CGFloat(pixels)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    let small = pixels <= 32

    // Tile: Apple's macOS grid puts an 824-pt body in a 1024 canvas.
    let margin = small ? size / 16 : size * 100 / 1024
    let tile = CGRect(x: margin, y: margin, width: size - 2 * margin, height: size - 2 * margin)
    let radius = tile.width * 0.2237
    let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let sky = CGGradient(colorsSpace: space, colors: [rgb(0x0B1626), rgb(0x1C3A5E)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

    let unit = tile.width / 18
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: tile.minX + x * unit, y: tile.minY + y * unit) }
    let lamp = p(9, 12.9)

    // Beams: two soft wedges from the lamp to the tile edges.
    for side: CGFloat in [1, -1] {
        let wedge = CGMutablePath()
        wedge.move(to: lamp)
        wedge.addLine(to: p(9 + side * 10, small ? 16.6 : 16.2))
        wedge.addLine(to: p(9 + side * 10, small ? 12.2 : 12.9))
        wedge.closeSubpath()
        ctx.saveGState()
        ctx.addPath(wedge)
        ctx.clip()
        let beam = CGGradient(colorsSpace: space, colors: [rgb(0xFFC861, small ? 0.95 : 0.9), rgb(0xFFC861, small ? 0.55 : 0)] as CFArray,
                              locations: [0, 1])!
        ctx.drawLinearGradient(beam, start: lamp, end: p(9 + side * 10, 14), options: [])
        ctx.restoreGState()
    }

    // Sea line.
    ctx.setFillColor(rgb(0x2C5684))
    ctx.fill(CGRect(x: tile.minX, y: tile.minY, width: tile.width, height: 2.5 * unit))

    // Tower (tapered), lamp room, cap.
    let spread: CGFloat = small ? 0.5 : 0
    let tower = CGMutablePath()
    tower.move(to: p(5.9 - spread, 2.5))
    tower.addLine(to: p(7.3 - spread / 2, 11))
    tower.addLine(to: p(10.7 + spread / 2, 11))
    tower.addLine(to: p(12.1 + spread, 2.5))
    tower.closeSubpath()
    ctx.setFillColor(rgb(0xF4F1EA))
    ctx.addPath(tower)
    ctx.fillPath()
    if !small {
        // One band, kept off the small sizes where it would muddy the tower.
        ctx.saveGState()
        ctx.addPath(tower)
        ctx.clip()
        ctx.setFillColor(rgb(0xD9534A))
        ctx.fill(CGRect(x: tile.minX, y: p(0, 5.6).y, width: tile.width, height: 1.6 * unit))
        ctx.restoreGState()
    }
    ctx.setFillColor(rgb(0xFFC861))
    ctx.fill(CGRect(origin: p(7.5 - spread / 2, 11.6), size: CGSize(width: (3 + spread) * unit, height: 2.4 * unit)))
    let cap = CGMutablePath()
    cap.move(to: p(6.9 - spread / 2, 14))
    cap.addLine(to: p(9, 16.1))
    cap.addLine(to: p(11.1 + spread / 2, 14))
    cap.closeSubpath()
    ctx.setFillColor(rgb(0xF4F1EA))
    ctx.addPath(cap)
    ctx.fillPath()
    ctx.restoreGState()

    // Hairline edge so the tile holds on dark backgrounds.
    if !small {
        ctx.addPath(tilePath)
        ctx.setStrokeColor(rgb(0xFFFFFF, 0.12))
        ctx.setLineWidth(size / 512)
        ctx.strokePath()
    }
    return ctx.makeImage()!
}

let entries: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
var images: [[String: String]] = []
for entry in entries {
    let name = "icon_\(entry.points)x\(entry.points)\(entry.scale == 2 ? "@2x" : "").png"
    let url = URL(fileURLWithPath: folder).appendingPathComponent(name)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, render(pixels: entry.points * entry.scale), nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(name)") }
    images.append(["filename": name, "idiom": "mac", "scale": "\(entry.scale)x", "size": "\(entry.points)x\(entry.points)"])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: URL(fileURLWithPath: folder).appendingPathComponent("Contents.json"))
print("wrote \(entries.count) icons to \(folder)")
