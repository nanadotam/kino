// Renders the Kino app icon to a 1024x1024 PNG.
// Usage: swift scripts/make-icon.swift icons/icon.png
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let size = 1024
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS icon grid: ~824px body centred in 1024 canvas.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

// soft drop shadow
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -10)
NSGraphicsContext.saveGraphicsState()
shadow.set()
NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.11, alpha: 1).setFill()
path.fill()
NSGraphicsContext.restoreGraphicsState()

let grad = NSGradient(
    starting: NSColor(calibratedRed: 0.16, green: 0.16, blue: 0.19, alpha: 1),
    ending: NSColor(calibratedRed: 0.035, green: 0.035, blue: 0.045, alpha: 1))!
grad.draw(in: path, angle: -90)

// thin inner border
NSColor.white.withAlphaComponent(0.08).setStroke()
let border = NSBezierPath(roundedRect: body.insetBy(dx: 3, dy: 3), xRadius: 182, yRadius: 182)
border.lineWidth = 6
border.stroke()

// sparkles glyph
let cfg = NSImage.SymbolConfiguration(pointSize: 470, weight: .medium)
if let sym = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?
    .withSymbolConfiguration(cfg) {
    let tinted = NSImage(size: sym.size, flipped: false) { r in
        sym.draw(in: r)
        NSColor.white.set()
        r.fill(using: .sourceAtop)
        return true
    }
    let s = tinted.size
    let r = NSRect(x: (CGFloat(size) - s.width) / 2, y: (CGFloat(size) - s.height) / 2,
                   width: s.width, height: s.height)
    tinted.draw(in: r)
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
