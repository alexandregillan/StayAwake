// Generates AppIcon.icns: the SF Symbol coffee cup on a macOS-style rounded
// square. Run via scripts/make-icon.sh. Output is committed to Resources/ so
// installing the app never needs to run this.
import Cocoa

let outDir = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let coffeeTop    = NSColor(calibratedRed: 0.52, green: 0.33, blue: 0.19, alpha: 1)
let coffeeBottom = NSColor(calibratedRed: 0.27, green: 0.15, blue: 0.08, alpha: 1)
let cream        = NSColor(calibratedRed: 1.00, green: 0.95, blue: 0.86, alpha: 1)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let s = CGFloat(px)
    // Apple's icon grid: the rounded square occupies ~80% of the canvas.
    let inset = s * 0.10
    let square = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = square.width * 0.225
    let shape = NSBezierPath(roundedRect: square, xRadius: radius, yRadius: radius)

    NSGradient(starting: coffeeTop, ending: coffeeBottom)!.draw(in: shape, angle: -90)

    // Soft highlight across the top half for a little depth.
    let gloss = NSGradient(starting: NSColor.white.withAlphaComponent(0.18),
                           ending: NSColor.white.withAlphaComponent(0.0))!
    NSGraphicsContext.current?.saveGraphicsState()
    shape.addClip()
    gloss.draw(in: NSRect(x: square.minX, y: square.midY, width: square.width, height: square.height / 2),
               angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()

    let config = NSImage.SymbolConfiguration(pointSize: s * 0.40, weight: .medium)
        .applying(NSImage.SymbolConfiguration(paletteColors: [cream]))
    guard let symbol = NSImage(systemSymbolName: "cup.and.saucer.fill",
                               accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else {
        fatalError("SF Symbol cup.and.saucer.fill not available")
    }
    let target = s * 0.52
    let scale = target / max(symbol.size.width, symbol.size.height)
    let w = symbol.size.width * scale, h = symbol.size.height * scale
    let origin = NSPoint(x: (s - w) / 2, y: (s - h) / 2 + s * 0.01)
    symbol.draw(in: NSRect(origin: origin, size: NSSize(width: w, height: h)),
                from: .zero, operation: .sourceOver, fraction: 1)

    return rep.representation(using: .png, properties: [:])!
}

let entries: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in entries {
    try render(px).write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}
print("Rendered \(entries.count) sizes into \(outDir)")
