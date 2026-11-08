// Draws TapChat's app icon: a near-black tile with a flat blue capsule (the
// bar you summon) holding a white bolt. Flat: no gradients.
// Usage: swift scripts/make-icon.swift out.png  (1024 × 1024)
import AppKit

let S: CGFloat = 1024

func bolt(in b: NSRect) -> NSBezierPath {
    let pts: [(CGFloat, CGFloat)] = [(0.64, 1.0), (0.10, 0.42), (0.47, 0.42), (0.36, 0.0), (0.90, 0.60), (0.53, 0.60)]
    let p = NSBezierPath()
    for (i, (x, y)) in pts.enumerated() {
        let pt = NSPoint(x: b.minX + x * b.width, y: b.minY + y * b.height)
        i == 0 ? p.move(to: pt) : p.line(to: pt)
    }
    p.close()
    return p
}

let image = NSImage(size: NSSize(width: S, height: S), flipped: false) { _ in
    let ctx = NSGraphicsContext.current!

    // Tile: near-black, flat, with a soft shadow and a faint light edge.
    let tileRect = NSRect(x: 100, y: 100, width: 824, height: 824)
    let tile = NSBezierPath(roundedRect: tileRect, xRadius: 185, yRadius: 185)
    ctx.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
    shadow.shadowBlurRadius = 26
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor(srgbRed: 0.075, green: 0.075, blue: 0.08, alpha: 1).setFill()
    tile.fill()
    ctx.restoreGraphicsState()
    let edge = NSBezierPath(roundedRect: tileRect.insetBy(dx: 1.5, dy: 1.5), xRadius: 184, yRadius: 184)
    edge.lineWidth = 3
    NSColor.white.withAlphaComponent(0.09).setStroke()
    edge.stroke()

    // The bar: a flat blue capsule.
    let bar = NSRect(x: 214, y: 392, width: 596, height: 240)
    let capsule = NSBezierPath(roundedRect: bar, xRadius: bar.height / 2, yRadius: bar.height / 2)
    ctx.saveGraphicsState()
    let bs = NSShadow()
    bs.shadowColor = NSColor.black.withAlphaComponent(0.5)
    bs.shadowBlurRadius = 24
    bs.shadowOffset = NSSize(width: 0, height: -10)
    bs.set()
    NSColor(srgbRed: 0.20, green: 0.50, blue: 0.98, alpha: 1).setFill()
    capsule.fill()
    ctx.restoreGraphicsState()
    // The bolt, white, where the cursor would be.
    NSColor.white.setFill()
    bolt(in: NSRect(x: 422, y: 422, width: 180, height: 180)).fill()
    return true
}

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
