import AppKit
import SwiftMath

// LaTeX in answers: \( … \) and $ … $ inline, \[ … \] and $$ … $$ on lines of
// their own. Typeset by SwiftMath (Latin Modern, the TeX look) and drawn as
// text attachments, in the text's own colour (so it follows light and dark),
// selectable with the text; copied, it's the LaTeX again.

// Inline spans in a line of text: \( … \), \[ … \] or $$ … $$ within a line,
// and $ … $ when it can't be a price ("$5 and $10" isn't math): no space just
// inside the dollars, no digit just after the closing one.
private let inlineMath = try! NSRegularExpression(pattern:
    #"\\\((.+?)\\\)|\\\[(.+?)\\\]|\$\$(.+?)\$\$|(?<![\\$])\$(?=\S)([^$\n]+?)(?<=\S)\$(?![\d$])"#)

/// `s` split into text and math, in order.
func mathSegments(_ s: String) -> [(text: String, isMath: Bool)] {
    guard s.contains("\\(") || s.contains("\\[") || s.contains("$") else { return [(s, false)] }
    let ns = s as NSString
    var out: [(String, Bool)] = []
    var at = 0
    for m in inlineMath.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
        guard let r = (1...4).lazy.map({ m.range(at: $0) }).first(where: { $0.location != NSNotFound }) else { continue }
        if m.range.location > at { out.append((ns.substring(with: NSRange(location: at, length: m.range.location - at)), false)) }
        out.append((ns.substring(with: r).trimmingCharacters(in: .whitespaces), true))
        at = NSMaxRange(m.range)
    }
    if at < ns.length { out.append((ns.substring(from: at), false)) }
    return out
}

// An inline math span travels through the AttributedString as a link with
// this scheme (the only custom data a parsed run carries); nsInline turns it
// into the formula.
let mathScheme = "tapchat-math"

func mathLink(_ latex: String) -> URL? {
    var c = URLComponents()
    c.scheme = mathScheme
    c.path = latex
    return c.url
}

func latex(fromMathLink url: URL) -> String? {
    guard url.scheme == mathScheme else { return nil }
    return URLComponents(url: url, resolvingAgainstBaseURL: false)?.path
}

/// The formula as one attachment character, or nil when it doesn't parse
/// (then the caller shows the LaTeX as it is).
func mathString(_ latex: String, size: CGFloat, display: Bool) -> NSAttributedString? {
    guard let cell = MathCell(latex: latex, size: size, display: display) else { return nil }
    let attachment = NSTextAttachment()
    attachment.attachmentCell = cell
    let a = NSMutableAttributedString(attachment: attachment)
    a.addAttributes([.font: NSFont.systemFont(ofSize: size), .tapChatMath: latex], range: NSRange(location: 0, length: a.length))
    return a
}

final class MathCell: NSTextAttachmentCell {
    let latex: String
    private let label: MTMathUILabel
    private let natural: NSSize
    private let descent: CGFloat

    init?(latex: String, size: CGFloat, display: Bool) {
        let label = MTMathUILabel()
        label.displayErrorInline = false
        label.labelMode = display ? .display : .text
        label.fontSize = size * (display ? 1.12 : 1.06)
        label.contentInsets = MTEdgeInsets()
        label.latex = latex
        guard label.error == nil, label.mathList != nil else { return nil }
        let fit = label.fittingSize
        guard fit.width > 0 else { return nil }
        // Laid out at its own size, SwiftMath puts the baseline `descent` up
        // from the bottom (at least half the font size tall, as it lays out).
        let height = max(fit.height, label.fontSize / 2)
        label.frame = NSRect(x: 0, y: 0, width: fit.width, height: height)
        label.layout()
        guard let list = label.displayList else { return nil }
        self.latex = latex
        self.label = label
        self.natural = NSSize(width: ceil(fit.width) + 1, height: ceil(height))
        self.descent = list.descent
        super.init(textCell: "")
    }

    required init(coder: NSCoder) { fatalError() }

    override func cellSize() -> NSSize { natural }
    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -descent) }
    override func wantsToTrackMouse() -> Bool { false }

    // A display formula wider than the text is scaled down to fit.
    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
                            glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        let s = lineFrag.width > 0 ? min(1, (lineFrag.width - 2) / natural.width) : 1
        return NSRect(x: 0, y: -descent * s, width: natural.width * s, height: natural.height * s)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        guard let context = NSGraphicsContext.current?.cgContext, let list = label.displayList else { return }
        // The text colour now, in the view's appearance.
        label.textColor = NSColor.labelColor
        let s = cellFrame.width / natural.width
        context.saveGState()
        // The text view is flipped; SwiftMath draws with y up from the baseline.
        context.translateBy(x: cellFrame.minX, y: cellFrame.maxY)
        context.scaleBy(x: s, y: -s)
        // AppKit leaves a flipped text matrix for its own text; glyphs here
        // are drawn in the y-up space just set.
        context.textMatrix = .identity
        list.draw(context)
        context.restoreGState()
    }
}

extension NSAttributedString.Key {
    // A formula's LaTeX, on its attachment character: what's copied.
    static let tapChatMath = NSAttributedString.Key("TapChatMath")
}

extension NSAttributedString {
    /// The text with each formula as its LaTeX (for copying).
    var withLatex: String {
        let out = NSMutableString(string: string)
        enumerateAttribute(.tapChatMath, in: NSRange(location: 0, length: length), options: .reverse) { value, range, _ in
            guard let latex = value as? String else { return }
            out.replaceCharacters(in: range, with: latex)
        }
        return out as String
    }
}
