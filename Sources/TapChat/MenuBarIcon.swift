import AppKit

// The menu bar glyph: TapChat's capsule with the bolt cut out of it, as a
// template image so macOS tints it for light and dark menu bars.
enum MenuBarIcon {
    static let image: NSImage = {
        let img = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            let r = NSRect(x: 1, y: 4, width: 18, height: 10)
            NSColor.black.setFill()
            NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
            let b = NSRect(x: 7.4, y: 5.2, width: 5.2, height: 7.6)
            let pts: [(CGFloat, CGFloat)] = [(0.64, 1.0), (0.10, 0.42), (0.47, 0.42), (0.36, 0.0), (0.90, 0.60), (0.53, 0.60)]
            let bolt = NSBezierPath()
            for (i, (x, y)) in pts.enumerated() {
                let pt = NSPoint(x: b.minX + x * b.width, y: b.minY + y * b.height)
                i == 0 ? bolt.move(to: pt) : bolt.line(to: pt)
            }
            bolt.close()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            bolt.fill()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "TapChat"
        return img
    }()
}
