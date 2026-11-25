// Renders the app icon into an .iconset folder: swift scripts/make-icon.swift <out.iconset> [preview.png]
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    // drop shadow
    let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.35); sh.shadowBlurRadius = 28 * s
    sh.shadowOffset = NSSize(width: 0, height: -10 * s); sh.set()
    NSColor(calibratedRed: 0.36, green: 0.32, blue: 0.96, alpha: 1).setFill(); shape.fill()
    NSShadow().set()
    NSGradient(colors: [NSColor(calibratedRed: 0.20, green: 0.42, blue: 1.00, alpha: 1),
                        NSColor(calibratedRed: 0.47, green: 0.27, blue: 0.95, alpha: 1),
                        NSColor(calibratedRed: 0.80, green: 0.25, blue: 0.75, alpha: 1)])!
        .draw(in: shape, angle: -60)
    // motion arcs
    NSColor.white.withAlphaComponent(0.28).setStroke()
    for (i, r) in [300.0, 360.0].enumerated() {
        let arc = NSBezierPath()
        arc.appendArc(withCenter: NSPoint(x: 512 * s, y: 470 * s), radius: CGFloat(r) * s,
                      startAngle: 35 + CGFloat(i) * 4, endAngle: 75 - CGFloat(i) * 4)
        arc.lineWidth = 26 * s; arc.lineCapStyle = .round; arc.stroke()
        let arc2 = NSBezierPath()
        arc2.appendArc(withCenter: NSPoint(x: 512 * s, y: 470 * s), radius: CGFloat(r) * s,
                       startAngle: 105 + CGFloat(i) * 4, endAngle: 145 - CGFloat(i) * 4)
        arc2.lineWidth = 26 * s; arc2.lineCapStyle = .round; arc2.stroke()
    }
    // hand symbol
    let cfg = NSImage.SymbolConfiguration(pointSize: 470 * s, weight: .semibold)
    if let sym = NSImage(systemSymbolName: "hand.raised.fingers.spread.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) {
        let tinted = NSImage(size: sym.size, flipped: false) { r in
            sym.draw(in: r); NSColor.white.set(); r.fill(using: .sourceAtop); return true
        }
        let hs = NSShadow(); hs.shadowColor = NSColor.black.withAlphaComponent(0.25); hs.shadowBlurRadius = 20 * s
        hs.shadowOffset = NSSize(width: 0, height: -8 * s); hs.set()
        let w = tinted.size.width, h = tinted.size.height
        tinted.draw(in: NSRect(x: 512 * s - w / 2, y: 470 * s - h / 2, width: w, height: h))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("icon_\(name).png"))
}
if CommandLine.arguments.count > 2 {
    try! render(512).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}
