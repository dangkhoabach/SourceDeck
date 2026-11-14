// Renders the app icon set from code: on the near-black rounded square all
// of the author's apps share, a branch leaving a line of commits, in one gradient, so the project needs
// no design tool to produce SourceDeckApp/Resources/Assets.xcassets/AppIcon.appiconset.
//
// Run once (or whenever the look changes):
//   swift scripts/generate-app-icon.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.first!).deletingLastPathComponent().deletingLastPathComponent()
let iconset = root.appendingPathComponent("SourceDeckApp/Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

/// A stroked path through `points`, with round ends and corners.
func line(_ points: [NSPoint], width: CGFloat = 44) -> NSBezierPath {
    let path = NSBezierPath()
    path.lineWidth = width
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.move(to: points[0])
    points.dropFirst().forEach { path.line(to: $0) }
    return path
}

func commit(_ center: NSPoint) -> NSBezierPath {
    let path = NSBezierPath(ovalIn: NSRect(x: center.x - 52, y: center.y - 52, width: 104, height: 104))
    path.lineWidth = 44
    return path
}

/// Drawn on a 1024-point canvas; every size is scaled down from it.
func drawIcon() {
    // macOS icon grid: the squircle occupies ~80% of the canvas.
    color(0x121214).setFill()
    NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185).fill()

    // Two commits on the main line, a third on the branch that curves off it.
    let branch = NSBezierPath()
    branch.lineWidth = 44
    branch.lineCapStyle = .round
    branch.move(to: NSPoint(x: 654, y: 672))
    branch.curve(to: NSPoint(x: 370, y: 420), controlPoint1: NSPoint(x: 654, y: 520), controlPoint2: NSPoint(x: 370, y: 560))
    let strokes = [line([NSPoint(x: 370, y: 352), NSPoint(x: 370, y: 672)]), branch,
                   commit(NSPoint(x: 370, y: 300)), commit(NSPoint(x: 370, y: 724)), commit(NSPoint(x: 654, y: 724))]

    // All of it white in a layer, then tinted with one gradient.
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext.current!.cgContext
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    NSColor.white.setStroke()
    NSColor.white.setFill()
    strokes.forEach { $0.stroke() }
    NSGraphicsContext.current!.compositingOperation = .sourceIn
    NSGradient(colors: [color(0xFDA4AF), color(0xF43F5E)])!.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024), angle: -90)
    context.endTransparencyLayer()
    NSGraphicsContext.restoreGraphicsState()
}

// Contents.json already lists these file names, so only the pictures are written.
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let pixels = points * scale
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    context.imageInterpolation = .high
    NSGraphicsContext.current = context
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(pixels) / 1024)
    transform.concat()
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
}
print("Wrote 10 icons to \(iconset.path)")
