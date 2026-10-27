// Renders the app icon set from code: a dark rounded square with a git
// branch glyph, so the project needs no design tool to produce
// SourceDeckApp/Resources/Assets.xcassets/AppIcon.appiconset.
// Placeholder look until the brand glyph and colour for this product are
// chosen.
//
// Run once (or whenever the look changes):
//   swift scripts/generate-app-icon.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.first!).deletingLastPathComponent().deletingLastPathComponent()
let iconset = root.appendingPathComponent("SourceDeckApp/Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    // macOS icon grid: the squircle occupies ~80% of the canvas.
    let inset = size * 0.1
    let square = rect.insetBy(dx: inset, dy: inset)
    let path = NSBezierPath(roundedRect: square, xRadius: square.width * 0.225, yRadius: square.width * 0.225)
    NSGradient(colors: [NSColor(red: 0.13, green: 0.16, blue: 0.24, alpha: 1), NSColor(red: 0.05, green: 0.07, blue: 0.12, alpha: 1)])!
        .draw(in: path, angle: -90)
    let symbol = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)!
        .withSymbolConfiguration(.init(pointSize: size * 0.42, weight: .semibold))!
    let tinted = NSImage(size: symbol.size)
    tinted.lockFocus()
    NSColor(red: 1.0, green: 0.55, blue: 0.40, alpha: 1).set()
    symbol.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
    NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
    tinted.unlockFocus()
    let glyph = NSRect(x: (size - tinted.size.width) / 2, y: (size - tinted.size.height) / 2, width: tinted.size.width, height: tinted.size.height)
    tinted.draw(in: glyph)
    image.unlockFocus()
    return image
}

var entries: [[String: String]] = []
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let pixels = CGFloat(points * scale)
    let image = render(size: pixels)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixels), pixelsHigh: Int(pixels), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    entries.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
}
let contents: [String: Any] = ["images": entries, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: iconset.appendingPathComponent("Contents.json"))
print("Wrote \(entries.count) icons to \(iconset.path)")
