// Renders the MacNotepad app icon (all macOS sizes) into an .iconset folder.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(_ size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    // Background squircle with a deep blue → teal gradient.
    let bg = NSBezierPath(roundedRect: NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s), xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [NSColor(calibratedRed: 0.09, green: 0.12, blue: 0.22, alpha: 1),
                        NSColor(calibratedRed: 0.07, green: 0.36, blue: 0.48, alpha: 1)])!.draw(in: bg, angle: -60)
    // Page
    let page = NSBezierPath(roundedRect: NSRect(x: 250 * s, y: 190 * s, width: 524 * s, height: 640 * s), xRadius: 48 * s, yRadius: 48 * s)
    NSColor(calibratedWhite: 0.98, alpha: 1).setFill()
    page.fill()
    // Heading bar + text lines + checkbox
    NSColor(calibratedRed: 0.09, green: 0.12, blue: 0.22, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 320 * s, y: 690 * s, width: 300 * s, height: 46 * s), xRadius: 23 * s, yRadius: 23 * s).fill()
    NSColor(calibratedWhite: 0.72, alpha: 1).setFill()
    for (i, w) in [380.0, 330, 360].enumerated() {
        NSBezierPath(roundedRect: NSRect(x: 320 * s, y: CGFloat(600 - i * 70) * s, width: CGFloat(w) * s, height: 26 * s), xRadius: 13 * s, yRadius: 13 * s).fill()
    }
    let accent = NSColor(calibratedRed: 0.20, green: 0.80, blue: 0.88, alpha: 1)
    accent.setStroke()
    let box = NSBezierPath(roundedRect: NSRect(x: 320 * s, y: 300 * s, width: 64 * s, height: 64 * s), xRadius: 14 * s, yRadius: 14 * s)
    box.lineWidth = 12 * s
    box.stroke()
    let check = NSBezierPath()
    check.move(to: NSPoint(x: 334 * s, y: 334 * s))
    check.line(to: NSPoint(x: 350 * s, y: 316 * s))
    check.line(to: NSPoint(x: 376 * s, y: 352 * s))
    check.lineWidth = 12 * s
    check.lineCapStyle = .round
    check.lineJoinStyle = .round
    check.stroke()
    NSColor(calibratedWhite: 0.72, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 410 * s, y: 319 * s, width: 250 * s, height: 26 * s), xRadius: 13 * s, yRadius: 13 * s).fill()
    // Tab strip hint on top of the page
    accent.setFill()
    NSBezierPath(roundedRect: NSRect(x: 250 * s, y: 790 * s, width: 524 * s, height: 40 * s), xRadius: 20 * s, yRadius: 20 * s).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! render(CGFloat(base * scale)).write(to: output.appendingPathComponent(name))
    }
}
