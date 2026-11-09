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

/// The formula as attachment characters (one, or one per part around a
/// \\boxed answer, which alone gets the frame), or nil when it doesn't parse
/// (then the caller shows the LaTeX as it is).
func mathString(_ latex: String, size: CGFloat, display: Bool) -> NSAttributedString? {
    let a = NSMutableAttributedString()
    for piece in mathPieces(latex) {
        guard let cell = MathCell(latex: piece.tex, size: size, display: display, boxed: piece.boxed) else { return nil }
        let attachment = NSTextAttachment()
        attachment.attachmentCell = cell
        a.append(NSAttributedString(attachment: attachment))
    }
    guard a.length > 0 else { return nil }
    // The whole formula on every part: copied, the parts become it once.
    a.addAttributes([.font: NSFont.systemFont(ofSize: size), .tapChatMath: latex], range: NSRange(location: 0, length: a.length))
    return a
}

/// Where a \\boxed{…} isn't inside anything else, the formula is split around it.
func mathPieces(_ tex: String) -> [(tex: String, boxed: Bool)] {
    var out: [(String, Bool)] = []
    var rest = Substring(tex)
    while let r = rest.range(of: #"\\boxed\s*\{"#, options: .regularExpression) {
        let before = rest[..<r.lowerBound]
        // Only at the top level: as many { as } before it.
        guard before.filter({ $0 == "{" }).count == before.filter({ $0 == "}" }).count else { break }
        var depth = 1
        var i = r.upperBound
        while i < rest.endIndex {
            if rest[i] == "{" { depth += 1 } else if rest[i] == "}" { depth -= 1; if depth == 0 { break } }
            i = rest.index(after: i)
        }
        guard i < rest.endIndex else { break }
        if !before.trimmingCharacters(in: .whitespaces).isEmpty { out.append((String(before), false)) }
        out.append((String(rest[r.upperBound..<i]), true))
        rest = rest[rest.index(after: i)...]
    }
    if !rest.trimmingCharacters(in: .whitespaces).isEmpty || out.isEmpty { out.append((String(rest), false)) }
    return out
}

// Common LaTeX SwiftMath doesn't know, rewritten to what it does.
private let rewrites: [(String, String)] = [
    (#"\\[dt]frac(?![a-zA-Z])"#, #"\\frac"#), (#"\\[dt]binom(?![a-zA-Z])"#, #"\\binom"#),
    (#"\\operatorname\*?(?![a-zA-Z])"#, #"\\mathrm"#), (#"\\dots[bcimo]?(?![a-zA-Z])"#, #"\\ldots"#),
    (#"\\implies(?![a-zA-Z])"#, #"\\Rightarrow"#), (#"\\impliedby(?![a-zA-Z])"#, #"\\Leftarrow"#),
    (#"\\pmod\s*\{([^{}]*)\}"#, #"\\ (\\mathrm{mod}\\ $1)"#), (#"\\[bp]?mod(?![a-zA-Z])"#, #"\\mathrm{mod}"#),
    // Delimiter sizes (\\bigl( and the like): the plain delimiter.
    (#"\\[Bb]igg?[lrm]?(?![a-zA-Z])"#, ""),
    (#"\\(?:tag|label)\*?\{[^{}]*\}"#, ""), (#"\\nonumber(?![a-zA-Z])|\\notag(?![a-zA-Z])"#, ""),
]

func supported(_ tex: String) -> String {
    var s = tex
    for (pattern, template) in rewrites {
        s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }
    // A \boxed{…} inside something else (mathPieces frames the others): its contents.
    while let r = s.range(of: #"\\boxed\s*\{"#, options: .regularExpression) {
        var depth = 1
        var i = r.upperBound
        while i < s.endIndex, depth > 0 {
            if s[i] == "{" { depth += 1 } else if s[i] == "}" { depth -= 1 }
            if depth > 0 { i = s.index(after: i) }
        }
        let inner = s[r.upperBound..<i]
        s.replaceSubrange(r.lowerBound..<(i < s.endIndex ? s.index(after: i) : i), with: inner)
    }
    return s
}

final class MathCell: NSTextAttachmentCell {
    let latex: String
    private let label: MTMathUILabel
    private let natural: NSSize
    private let descent: CGFloat

    private let boxed: Bool

    init?(latex: String, size: CGFloat, display: Bool, boxed: Bool = false) {
        let latex = supported(latex)
        let label = MTMathUILabel()
        label.displayErrorInline = false
        label.labelMode = display ? .display : .text
        label.fontSize = size * (display ? 1.12 : 1.06)
        label.contentInsets = MTEdgeInsets()
        label.latex = latex
        // A command SwiftMath doesn't know: without it, rather than none of
        // the formula (a few times at most).
        var tex = latex
        for _ in 0..<4 {
            guard let message = label.error?.localizedDescription,
                  let m = message.firstMatch(of: #/Invalid command (\\[a-zA-Z]+)/#) else { break }
            let command = String(m.1)
            tex = tex.replacingOccurrences(of: NSRegularExpression.escapedPattern(for: command) + "(?![a-zA-Z])", with: "", options: .regularExpression)
            label.latex = tex
        }
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
        self.boxed = boxed
        self.label = label
        let pad: CGFloat = boxed ? 4 : 0
        self.natural = NSSize(width: ceil(fit.width) + 1 + 2 * pad, height: ceil(height) + 2 * pad)
        self.descent = list.descent + pad
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
        if boxed {
            // An answer's box (\\boxed): a thin frame, the formula inside.
            NSColor.labelColor.withAlphaComponent(0.55).setStroke()
            let frame = NSBezierPath(roundedRect: NSRect(origin: .zero, size: natural).insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
            frame.lineWidth = 0.8 / max(s, 0.01)
            frame.stroke()
            context.translateBy(x: 4, y: 4)
        }
        list.draw(context)
        context.restoreGState()
    }
}

extension NSAttributedString.Key {
    // A formula's LaTeX, on its attachment character: what's copied.
    static let tapChatMath = NSAttributedString.Key("TapChatMath")
}

/// A formula as written in text: \\( … \\), so it's math again when quoted.
func delimited(_ tex: String) -> String { "\\(" + tex + "\\)" }

/// A formula as a template image (it takes the colour it's shown in), and
/// how far it reaches below the baseline: for a quote in a SwiftUI Text.
func mathImage(_ tex: String, size: CGFloat) -> (image: NSImage, descent: CGFloat)? {
    guard let cell = MathCell(latex: tex, size: size, display: false) else { return nil }
    let s = cell.cellSize()
    let image = NSImage(size: s, flipped: true) { rect in
        cell.draw(withFrame: rect, in: nil)
        return true
    }
    image.isTemplate = true
    return (image, -cell.cellBaselineOffset().y)
}

extension NSAttributedString {
    /// The text with each formula as its LaTeX (for copying).
    var withLatex: String {
        let out = NSMutableString(string: string)
        enumerateAttribute(.tapChatMath, in: NSRange(location: 0, length: length), options: .reverse) { value, range, _ in
            guard let latex = value as? String else { return }
            out.replaceCharacters(in: range, with: delimited(latex))
        }
        return out as String
    }

    /// Where `part`, text with its formulas as LaTeX (as highlights are kept),
    /// is in this text: matches that start and end between formulas, never
    /// inside one. (A formula is one character here; searched as that, one
    /// highlighted formula matched them all.)
    func ranges(ofLatexText part: String) -> [NSRange] {
        let full = NSRange(location: 0, length: length)
        var formulas: [(latex: NSRange, own: NSRange)] = []
        let expanded = NSMutableString()
        var at = 0
        enumerateAttribute(.tapChatMath, in: full) { value, range, _ in
            guard let tex = value as? String else { return }
            expanded.append((string as NSString).substring(with: NSRange(location: at, length: range.location - at)))
            let shown = delimited(tex)
            formulas.append((NSRange(location: expanded.length, length: (shown as NSString).length), range))
            expanded.append(shown)
            at = NSMaxRange(range)
        }
        expanded.append((string as NSString).substring(from: at))
        // A position in the expanded text, in this one; nil inside a formula's
        // LaTeX (a match there is part of another formula, not this highlight).
        func own(_ p: Int) -> Int? {
            var delta = 0
            for f in formulas {
                if p >= NSMaxRange(f.latex) { delta += f.latex.length - f.own.length; continue }
                if p > f.latex.location { return nil }
                break
            }
            return p - delta
        }
        var out: [NSRange] = []
        var from = 0
        while from < expanded.length {
            let r = expanded.range(of: part, range: NSRange(location: from, length: expanded.length - from))
            guard r.location != NSNotFound, r.length > 0 else { break }
            if let a = own(r.location), let b = own(NSMaxRange(r)), b > a { out.append(NSRange(location: a, length: b - a)) }
            from = NSMaxRange(r)
        }
        return out
    }
}
