import AppKit
import SwiftUI

// A small Markdown renderer: paragraphs, headings, lists, quotes, code blocks
// and tables, with inline styles from AttributedString.
//
// Fast for long and streaming answers:
// - Text is parsed once into blocks whose inline styles are resolved up front
//   (MarkdownDocument), and kept per message (MarkdownCache).
// - While an answer streams in, only the text after the last finished block
//   is parsed again (see `parseBlocks`, which reports where that is).
// - Everything between code blocks is one selectable text (TextGroup), so a
//   selection can run across paragraphs, lists and tables; while an answer
//   streams in, only the changed end of that text is replaced.
struct MarkdownView: View {
    let text: String
    // The message the text belongs to: its parse is kept and reused. nil: parsed each time (short texts).
    var id: UUID?
    // While an answer streams in: how many of the newest characters are still fading in.
    var fadeTail = 0
    // Parts marked with Highlight.
    var highlights: [String] = []

    var body: some View {
        let blocks = id.map { MarkdownCache.shared.blocks(for: $0, text: text) } ?? parseBlocks(Substring(text)).blocks
        let groups = markdownGroups(blocks)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(groups.indices, id: \.self) { i in
                let fade = i == groups.count - 1 ? fadeTail : 0
                switch groups[i] {
                case .code(let block):
                    BlockView(block: block, fadeTail: fade, highlights: highlights).equatable()
                case .text(let blocks):
                    TextGroup(blocks: blocks, fadeTail: fade, highlights: highlights).equatable()
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// One block. Equal when it's the same parsed block (the same object) with the
// same fade, so SwiftUI skips it.
struct BlockView: View, Equatable {
    let block: MDBlock
    var fadeTail = 0
    var highlights: [String] = []

    static func == (a: BlockView, b: BlockView) -> Bool { a.block === b.block && a.fadeTail == b.fadeTail && a.highlights == b.highlights }

    var body: some View {
        switch block.kind {
        case .paragraph(let s):
            Text(faded(s)).font(.system(size: 14)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let s):
            Text(faded(s))
                .font(.system(size: level == 1 ? 19 : level == 2 ? 17 : 15, weight: .semibold))
                .padding(.top, 4)
        case .list(let items):
            // One text for the whole list, so a selection can run across items.
            SelectableText(text: styledNS(listText(items)))
        case .quote(let s):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(.secondary.opacity(0.5)).frame(width: 3)
                Text(faded(s)).font(.system(size: 14)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .code(let lang, let code):
            CodeBlock(language: lang, code: code)
        case .table(let rows):
            // One text for the whole table (columns at tab stops), so a
            // selection can cover several cells or all of it; copied, it's
            // tab-separated, ready for a spreadsheet.
            ScrollView(.horizontal, showsIndicators: false) {
                SelectableText(text: styledNS(tableText(rows)), wraps: false)
                    .padding(.vertical, 4)
            }
        case .rule:
            Divider()
        case .math:
            SelectableText(text: block.ns)
        }
    }

    // The last ~30 characters ramp up from transparent; as the text grows
    // each character brightens over a few frames: a soft fade-in.
    private func faded(_ s: AttributedString) -> AttributedString {
        let s = marked(s)
        let n = min(fadeTail, s.characters.count)
        guard n > 0 else { return s }
        var a = s
        var i = a.characters.index(a.characters.endIndex, offsetBy: -n)
        var k = 0
        while i < a.characters.endIndex {
            let next = a.characters.index(after: i)
            let opacity = 1 - Double(k + 1) / Double(n + 1)
            a[i..<next].foregroundColor = Color.primary.opacity(0.15 + 0.85 * opacity)
            i = next
            k += 1
        }
        return a
    }
}

struct CodeBlock: View {
    let language: String
    let code: String
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                        // The same height either way, so the block doesn't shift.
                        .frame(height: 16)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(hovering || copied ? 1 : 0)
            }
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(.system(size: 12.5, design: .monospaced)).padding(.horizontal, 12).padding(.bottom, 10)
                    .fixedSize(horizontal: true, vertical: true)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
        .onHover { hovering = $0 }
    }
}

// Highlighted parts get a soft yellow background, wherever they occur.
func highlighted(_ s: AttributedString, _ parts: [String]) -> AttributedString {
    guard !parts.isEmpty else { return s }
    var a = s
    for part in parts where !part.isEmpty {
        var from = a.startIndex
        while from < a.endIndex, let r = a[from...].range(of: part) {
            a[r].backgroundColor = Color.yellow.opacity(0.3)
            from = r.upperBound
        }
    }
    return a
}

extension BlockView {
    fileprivate func marked(_ s: AttributedString) -> AttributedString { highlighted(s, highlights) }

    // Highlights and the streaming fade-in, for a list or table drawn by AppKit.
    fileprivate func styledNS(_ base: NSAttributedString) -> NSAttributedString {
        let a = NSMutableAttributedString(attributedString: base)
        let text = a.string as NSString
        for part in highlights where !part.isEmpty {
            var from = 0
            while from < text.length {
                let r = text.range(of: part, range: NSRange(location: from, length: text.length - from))
                guard r.location != NSNotFound else { break }
                a.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.3), range: r)
                from = NSMaxRange(r)
            }
        }
        let n = min(fadeTail, text.length)
        for k in 0..<n {
            let opacity = 1 - Double(k + 1) / Double(n + 1)
            a.addAttribute(.foregroundColor, value: NSColor.labelColor.withAlphaComponent(0.15 + 0.85 * opacity),
                           range: NSRange(location: text.length - n + k, length: 1))
        }
        return a
    }
}

// The blocks between code blocks, drawn as one text; code blocks on their own.
enum MDGroup {
    case text([MDBlock])
    case code(MDBlock)

    // Its text as drawn (what a selection in it is part of).
    var plain: String {
        switch self {
        case .code(let b): return b.plainTexts.first ?? ""
        case .text(let blocks): return blocks.map { $0.ns.string }.joined(separator: "\n")
        }
    }
}

// The whole answer is one text, code blocks included (drawn in their boxes
// by MessageTextView), so a selection can run through all of it.
func markdownGroups(_ blocks: [MDBlock]) -> [MDGroup] {
    blocks.isEmpty ? [] : [.text(blocks)]
}

// Paragraphs, headings, lists, quotes, tables and rules as one selectable
// text. Equal (skipped by SwiftUI) when it's the same blocks, fade and highlights.
struct TextGroup: View, Equatable {
    let blocks: [MDBlock]
    var fadeTail = 0
    var highlights: [String] = []

    static func == (a: TextGroup, b: TextGroup) -> Bool {
        a.fadeTail == b.fadeTail && a.highlights == b.highlights && a.blocks.count == b.blocks.count
            && zip(a.blocks, b.blocks).allSatisfy { $0 === $1 }
    }

    private static func isCode(_ b: MDBlock) -> Bool {
        if case .code = b.kind { return true }
        return false
    }

    private static func gapAfter(_ b: MDBlock) -> CGFloat? {
        switch b.kind {
        case .list: return 5
        case .table: return 7
        case .code: return 10
        default: return nil
        }
    }

    var body: some View {
        let text = NSMutableAttributedString()
        for (i, b) in blocks.enumerated() {
            if i > 0 { text.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 14)])) }
            // A code block first: AppKit drops the space above the first
            // paragraph, so a hairline of a paragraph goes before it.
            if i == 0, case .code = b.kind {
                text.append(NSAttributedString(string: "\u{200B}\n", attributes: [.font: NSFont.systemFont(ofSize: 1)]))
            }
            // After a list or table (whose own last line keeps its tighter
            // spacing, so it doesn't change when the next item streams in),
            // the next block adds the rest of the 10 pt gap above itself.
            if i > 0, let extra = Self.gapAfter(blocks[i - 1]), !Self.isCode(b) {
                let a = NSMutableAttributedString(attributedString: b.ns)
                a.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: min(1, a.length))) { value, _, _ in
                    let p = ((value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                    p.paragraphSpacingBefore += extra
                    let first = (a.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
                    a.addAttribute(.paragraphStyle, value: p, range: first)
                }
                text.append(a)
            } else {
                text.append(b.ns)
            }
        }
        return SelectableText(text: styled(text, highlights: highlights, fadeTail: fadeTail), restyle: highlights.hashValue)
    }
}

// Highlights (soft yellow) and the streaming fade-in on AppKit text.
func styled(_ base: NSAttributedString, highlights: [String], fadeTail: Int) -> NSAttributedString {
    guard !highlights.isEmpty || fadeTail > 0 else { return base }
    let a = NSMutableAttributedString(attributedString: base)
    let text = a.string as NSString
    for part in highlights where !part.isEmpty {
        var from = 0
        while from < text.length {
            let r = text.range(of: part, range: NSRange(location: from, length: text.length - from))
            guard r.location != NSNotFound else { break }
            a.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.3), range: r)
            from = NSMaxRange(r)
        }
    }
    let n = min(fadeTail, text.length)
    for k in 0..<n {
        let opacity = 1 - Double(k + 1) / Double(n + 1)
        a.addAttribute(.foregroundColor, value: NSColor.labelColor.withAlphaComponent(0.15 + 0.85 * opacity),
                       range: NSRange(location: text.length - n + k, length: 1))
    }
    return a
}

// Gaps matching the stacked layout this replaced: between blocks 10 pt
// (3 pt line spacing + 7), between list items 5 (3 + 2).
private func paragraphStyle(spacing: CGFloat = 7, before: CGFloat = 0, lineSpacing: CGFloat = 3) -> NSMutableParagraphStyle {
    let p = NSMutableParagraphStyle()
    p.lineSpacing = lineSpacing
    p.paragraphSpacing = spacing
    p.paragraphSpacingBefore = before
    return p
}

extension MDBlock {
    // The block in AppKit attributes, made once (blocks never change).
    func makeNS() -> NSAttributedString {
        switch kind {
        case .paragraph(let s):
            let a = nsInline(s, size: 14)
            a.addAttribute(.paragraphStyle, value: paragraphStyle(), range: NSRange(location: 0, length: a.length))
            return a
        case .heading(let level, let s):
            let a = nsInline(s, size: level == 1 ? 19 : level == 2 ? 17 : 15, weight: .semibold)
            a.addAttribute(.paragraphStyle, value: paragraphStyle(spacing: 10, before: 4, lineSpacing: 0), range: NSRange(location: 0, length: a.length))
            return a
        case .list(let items):
            return listText(items)
        case .quote(let s):
            // A bar on the left, like the stacked layout's.
            let a = nsInline(s, size: 14)
            a.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: 0, length: a.length))
            let bar = NSTextBlock()
            bar.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
            bar.setBorderColor(NSColor.secondaryLabelColor.withAlphaComponent(0.5), for: .minX)
            bar.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
            let p = paragraphStyle()
            p.textBlocks = [bar]
            a.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: a.length))
            return a
        case .table(let rows):
            return tableText(rows)
        case .rule:
            // A hairline: an empty paragraph with a bottom border.
            let line = NSTextBlock()
            line.setWidth(0.5, type: .absoluteValueType, for: .border, edge: .maxY)
            line.setBorderColor(NSColor.separatorColor, for: .maxY)
            let p = paragraphStyle()
            p.textBlocks = [line]
            return NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: 6), .paragraphStyle: p])
        case .math(let tex):
            // Centred on a line of its own.
            let p = paragraphStyle()
            p.alignment = .center
            let a = NSMutableAttributedString(attributedString: mathString(tex, size: 14, display: true)
                ?? NSAttributedString(string: tex, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                                                                 .foregroundColor: NSColor.secondaryLabelColor]))
            a.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: a.length))
            return a
        case .code(let language, let code):
            // In a box (drawn by MessageTextView, from its first and last
            // lines): its lines indented 12 pt each side, 28 pt above the
            // first for the language and Copy, 10 below the last.
            let info = CodeInfo(language: language, code: code)
            let lines = (code.isEmpty ? " " : code).components(separatedBy: "\n")
            let out = NSMutableAttributedString()
            for (i, line) in lines.enumerated() {
                let p = paragraphStyle(spacing: i == lines.count - 1 ? 10 : 0, before: i == 0 ? 28 : 0, lineSpacing: 2)
                p.firstLineHeadIndent = 12
                p.headIndent = 12
                p.tailIndent = -12
                out.append(NSAttributedString(string: line + (i < lines.count - 1 ? "\n" : ""), attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular),
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: p,
                    .tapChatCode: info,
                ]))
            }
            return out
        }
    }
}

extension NSAttributedString.Key {
    // A code block's range in a message text, with its language and code.
    static let tapChatCode = NSAttributedString.Key("TapChatCode")
    // A table's range: its cells share one NSTextTable, so it's replaced whole.
    static let tapChatTable = NSAttributedString.Key("TapChatTable")
}

final class CodeInfo: NSObject {
    let language: String
    let code: String
    init(language: String, code: String) {
        self.language = language
        self.code = code
    }
}

// The message text: code blocks get a rounded box, their language and, on
// hover, a Copy button.
final class MessageTextView: NSTextView {
    // Formulas copy as their LaTeX.
    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string, let storage = textStorage else { return super.writeSelection(to: pboard, type: type) }
        let text = selectedRanges.map { storage.attributedSubstring(from: $0.rangeValue).withLatex }.joined(separator: "\n")
        return pboard.setString(text, forType: .string)
    }
    private var boxes: [(rect: NSRect, info: CodeInfo)] = []
    private var buttons: [NSButton] = []
    private var hovered: Int?
    private var copied: Int?

    // After layout: where the code boxes are.
    func refreshCodeBoxes() {
        guard let storage = textStorage, let layout = layoutManager, let container = textContainer else { return }
        var found: [(NSRect, CodeInfo)] = []
        storage.enumerateAttribute(.tapChatCode, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let info = value as? CodeInfo, range.length > 0 else { return }
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphs.length > 0 else { return }
            // From its first and last lines (inside the block's padding: 28 pt
            // above, 10 below), across the full width.
            // Its first line's rect starts with the 28 pt above it, its last
            // line's ends with the 10 below.
            let first = layout.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let last = layout.lineFragmentRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
            let rect = NSRect(x: 0, y: first.minY, width: container.size.width, height: last.maxY - first.minY)
            found.append((rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y), info))
        }
        boxes = found
        layoutButtons()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        for box in boxes where box.rect.intersects(dirtyRect) {
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            NSBezierPath(roundedRect: box.rect, xRadius: 10, yRadius: 10).fill()
            let label = box.info.language.isEmpty ? "code" : box.info.language
            (label as NSString).draw(at: NSPoint(x: box.rect.minX + 12, y: box.rect.minY + 8),
                                     withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        }
        super.draw(dirtyRect)
    }

    private func layoutButtons() {
        while buttons.count < boxes.count {
            let b = NSButton(title: "Copy", target: self, action: #selector(copyCode(_:)))
            b.isBordered = false
            b.font = .systemFont(ofSize: 11)
            b.contentTintColor = .secondaryLabelColor
            b.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
            b.imagePosition = .imageLeading
            addSubview(b)
            buttons.append(b)
        }
        while buttons.count > boxes.count { buttons.removeLast().removeFromSuperview() }
        for (i, b) in buttons.enumerated() {
            b.tag = i
            let done = copied == i
            b.title = done ? "Copied" : "Copy"
            b.image = NSImage(systemSymbolName: done ? "checkmark" : "doc.on.doc", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
            b.sizeToFit()
            let r = boxes[i].rect
            b.setFrameOrigin(NSPoint(x: r.maxX - b.frame.width - 10, y: r.minY + 5))
            b.isHidden = hovered != i && !done
        }
    }

    @objc private func copyCode(_ sender: NSButton) {
        guard boxes.indices.contains(sender.tag) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(boxes[sender.tag].info.code, forType: .string)
        Haptics.confirm()
        copied = sender.tag
        layoutButtons()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.copied = nil
            self?.layoutButtons()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.userInfo?["codeHover"] != nil { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: ["codeHover": true]))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let p = convert(event.locationInWindow, from: nil)
        let now = boxes.firstIndex { $0.rect.contains(p) }
        if now != hovered { hovered = now; layoutButtons() }
        if overPopup { NSCursor.arrow.set() }
    }

    // The selection bar or reply box above this text: an arrow there, like
    // over any button, not this text's I-beam.
    override func cursorUpdate(with event: NSEvent) {
        if overPopup { NSCursor.arrow.set() } else { super.cursorUpdate(with: event) }
    }

    private var overPopup: Bool {
        guard let w = window, let model = (w.delegate as? PanelController)?.model, !model.popupFrames.isEmpty,
              let height = w.contentView?.bounds.height else { return false }
        let p = w.mouseLocationOutsideOfEventStream
        let point = CGPoint(x: p.x, y: height - p.y)
        return model.popupFrames.values.contains { $0.contains(point) }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if hovered != nil { hovered = nil; layoutButtons() }
    }
}

// Inline Markdown (bold, italic, code, links) in AppKit attributes.
func nsInline(_ a: AttributedString, size: CGFloat, weight: NSFont.Weight = .regular) -> NSMutableAttributedString {
    let out = NSMutableAttributedString()
    for run in a.runs {
        let intent = run.inlinePresentationIntent ?? []
        var font = intent.contains(.code) ? NSFont.monospacedSystemFont(ofSize: size - 1, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        var traits: NSFontDescriptor.SymbolicTraits = []
        if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
        if intent.contains(.emphasized) { traits.insert(.italic) }
        if !traits.isEmpty { font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize) ?? font }
        if let link = run.link, let tex = latex(fromMathLink: link) {
            if let math = mathString(tex, size: size, display: false) { out.append(math); continue }
            // Doesn't parse: the LaTeX as written.
            out.append(NSAttributedString(string: tex, attributes: [.font: NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular),
                                                                     .foregroundColor: NSColor.secondaryLabelColor]))
            continue
        }
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        if let link = run.link { attrs[.link] = link }
        if intent.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        out.append(NSAttributedString(string: String(a[run.range].characters), attributes: attrs))
    }
    return out
}

// A list as one text: each item a paragraph with its marker hanging in the
// margin (right-aligned, then the text at a tab), wrapped lines indented.
func listText(_ items: [MDListItem]) -> NSAttributedString {
    let out = NSMutableAttributedString()
    for (n, item) in items.enumerated() {
        let indent = CGFloat(item.indent) * 16
        let para = NSMutableParagraphStyle()
        para.firstLineHeadIndent = indent
        para.headIndent = indent + 20
        para.tabStops = [NSTextTab(textAlignment: .right, location: indent + 14), NSTextTab(textAlignment: .left, location: indent + 20)]
        para.lineSpacing = 3
        para.paragraphSpacing = 2
        let start = out.length
        out.append(NSAttributedString(string: "\t\(item.marker)\t", attributes: [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.secondaryLabelColor]))
        out.append(nsInline(item.text, size: 14))
        if n < items.count - 1 { out.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 14)])) }
        out.addAttribute(.paragraphStyle, value: para, range: NSRange(location: start, length: out.length - start))
    }
    return out
}

// A table as a real text table (NSTextTable): each cell a paragraph in its
// column, wrapping inside it; columns as wide as their widest cell allows
// (at least 12% each); the header bold with a hairline under it.
private let unbroken = try! NSRegularExpression(pattern: "\\S+")

func tableText(_ rows: [[AttributedString]]) -> NSAttributedString {
    let cells = rows.enumerated().map { r, row in row.map { nsInline($0, size: 13, weight: r == 0 ? .semibold : .regular) } }
    let columns = cells.map(\.count).max() ?? 0
    guard columns > 0 else { return NSAttributedString() }
    // Each column's widest cell, and its longest word (which mustn't break).
    var natural = [CGFloat](repeating: 1, count: columns)
    var word = [CGFloat](repeating: 0, count: columns)
    for row in cells {
        for (c, cell) in row.enumerated() {
            natural[c] = max(natural[c], min(360, ceil(cell.size().width)))
            // Space-separated chunks: "read_food_diary(file)" is one.
            let text = cell.string as NSString
            for m in unbroken.matches(in: cell.string, range: NSRange(location: 0, length: text.length)) {
                word[c] = max(word[c], min(300, ceil(cell.attributedSubstring(from: m.range).size().width)))
            }
        }
    }
    // Shares of the width by widest cell; at least room for the longest word
    // (and the 14 pt gap) in a narrowish window (380 pt), and 12%.
    var share = natural.map { $0 / natural.reduce(0, +) * 100 }
    share = zip(share, word).map { max($0, 12, ($1 + 16) / 380 * 100) }
    share = share.map { $0 / share.reduce(0, +) * 100 }
    let table = NSTextTable()
    table.numberOfColumns = columns
    table.layoutAlgorithm = .automaticLayoutAlgorithm
    table.collapsesBorders = true
    let out = NSMutableAttributedString()
    for (r, row) in cells.enumerated() {
        for c in 0..<columns {
            let block = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
            block.setValue(share[c], type: .percentageValueType, for: .width)
            block.setWidth(c == columns - 1 ? 0 : 14, type: .absoluteValueType, for: .padding, edge: .maxX)
            block.setWidth(r == 0 ? 5 : 3, type: .absoluteValueType, for: .padding, edge: .maxY)
            if r == 1 { block.setWidth(3, type: .absoluteValueType, for: .padding, edge: .minY) }
            if r == 0 {
                block.setWidth(0.5, type: .absoluteValueType, for: .border, edge: .maxY)
                block.setBorderColor(.separatorColor, for: .maxY)
            }
            let p = NSMutableParagraphStyle()
            p.textBlocks = [block]
            let cell = c < row.count ? NSMutableAttributedString(attributedString: row[c]) : NSMutableAttributedString(string: "")
            if cell.length == 0 { cell.append(NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: 13)])) }
            let last = r == cells.count - 1 && c == columns - 1
            if !last { cell.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 13)])) }
            cell.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: cell.length))
            out.append(cell)
        }
    }
    out.addAttribute(.tapChatTable, value: table, range: NSRange(location: 0, length: out.length))
    return out
}

// Read-only, selectable text drawn by AppKit, as tall as it needs at the
// width it's given (or as wide as its lines, with `wraps` off).
struct SelectableText: NSViewRepresentable {
    let text: NSAttributedString
    var wraps = true
    // Changes when styling earlier in the text changes (highlights): then
    // the whole text is replaced, not just its end.
    var restyle = 0

    final class Coordinator { var restyle = 0 }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextView {
        let tv = MessageTextView(usingTextLayoutManager: false)
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = false
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.textStorage?.setAttributedString(text)
        context.coordinator.restyle = restyle
        return tv
    }

    // While an answer streams in, only its end changes (new text, the fade):
    // the end is replaced from a little before where the old and new texts
    // part, so only that much is laid out again.
    func updateNSView(_ tv: NSTextView, context: Context) {
        guard let storage = tv.textStorage else { return }
        let old = storage.string as NSString, new = text.string as NSString
        var start = max(0, min(old.length, new.length) - 120)
        // A code block or table reaching into the replaced end is replaced
        // whole (one box; one table, its cells sharing one NSTextTable).
        for key in [NSAttributedString.Key.tapChatCode, .tapChatTable] where start > 0 && start < new.length {
            var whole = NSRange()
            if text.attribute(key, at: start, longestEffectiveRange: &whole, in: NSRange(location: 0, length: new.length)) != nil {
                start = whole.location
            }
        }
        if context.coordinator.restyle == restyle, start > 0,
           old.substring(to: start) == new.substring(to: start) {
            let tail = text.attributedSubstring(from: NSRange(location: start, length: new.length - start))
            if !storage.attributedSubstring(from: NSRange(location: start, length: old.length - start)).isEqual(to: tail) {
                storage.replaceCharacters(in: NSRange(location: start, length: old.length - start), with: tail)
            }
        } else if !storage.isEqual(to: text) {
            storage.setAttributedString(text)
        }
        context.coordinator.restyle = restyle
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView tv: NSTextView, context: Context) -> CGSize? {
        guard let container = tv.textContainer, let layout = tv.layoutManager else { return nil }
        let width = wraps ? (proposal.width ?? 400) : 100_000
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        (tv as? MessageTextView)?.refreshCodeBoxes()
        let used = layout.usedRect(for: container)
        return CGSize(width: wraps ? width : ceil(used.width), height: ceil(used.height))
    }
}

// A parsed block, inline styles resolved. A class: views compare blocks by
// identity, which is free, and a block parsed once is shared from then on.
final class MDBlock: @unchecked Sendable {
    enum Kind {
        case paragraph(AttributedString)
        case heading(Int, AttributedString)
        case list([MDListItem])
        case quote(AttributedString)
        case code(String, String)
        case table([[AttributedString]])
        case rule
        case math(String)
    }
    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }
    // In AppKit attributes (TextGroup), made on first use, on the main thread.
    lazy var ns: NSAttributedString = makeNS()

    // Its text as drawn, one string per Text view (each is selected on its own).
    var plainTexts: [String] {
        switch kind {
        case .paragraph(let s), .heading(_, let s), .quote(let s): return [String(s.characters)]
        case .list(let items): return [listText(items).string]
        case .code(_, let code): return [code]
        case .table(let rows): return [tableText(rows).string]
        case .rule: return []
        case .math(let tex): return [tex]
        }
    }
}

struct MDListItem {
    var marker: String
    var text: AttributedString
    var indent: Int
}

func inlineMarkdown(_ s: String) -> AttributedString {
    // Formulas are taken out first: Markdown would eat their backslashes,
    // underscores and asterisks.
    var out = AttributedString()
    for part in mathSegments(s) {
        if part.isMath {
            var m = AttributedString(part.text)
            m.link = mathLink(part.text)
            out += m
        } else {
            out += (try? AttributedString(markdown: part.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(part.text)
        }
    }
    return out
}

// The blocks of `text`, plus a checkpoint: `stableCount` blocks lie wholly
// before UTF-8 offset `stableEnd`, where the parser is between blocks and no
// later text can change them. A streaming answer only grows, so next time
// only the text after that offset needs parsing.
struct ParseResult {
    var blocks: [MDBlock]
    var stableCount: Int
    var stableEnd: Int
}

func parseBlocks(_ text: Substring) -> ParseResult {
    var blocks: [MDBlock] = []
    var para: [Substring] = []
    var list: [(marker: String, text: String, indent: Int)] = []
    var quote: [String] = []
    var table: [[String]] = []
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    // UTF-8 offset where each line starts.
    var starts: [Int] = []
    starts.reserveCapacity(lines.count + 1)
    var offset = 0
    for line in lines {
        starts.append(offset)
        offset += line.utf8.count + 1
    }
    var stableCount = 0, stableEnd = 0
    var i = 0

    func flush() {
        if !para.isEmpty { blocks.append(MDBlock(.paragraph(inlineMarkdown(para.joined(separator: "\n"))))); para = [] }
        if !list.isEmpty {
            blocks.append(MDBlock(.list(list.map { MDListItem(marker: $0.marker, text: inlineMarkdown($0.text), indent: $0.indent) })))
            list = []
        }
        if !quote.isEmpty { blocks.append(MDBlock(.quote(inlineMarkdown(quote.joined(separator: "\n"))))); quote = [] }
        if !table.isEmpty { blocks.append(MDBlock(.table(table.map { $0.map(inlineMarkdown) }))); table = [] }
    }
    // After line `last` the parser holds nothing: if that line is complete
    // (a newline follows it), everything so far is final.
    func checkpoint(after last: Int) {
        guard last < lines.count - 1, para.isEmpty, list.isEmpty, quote.isEmpty, table.isEmpty else { return }
        stableCount = blocks.count
        stableEnd = starts[last + 1]
    }

    while i < lines.count {
        let line = lines[i]
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") {
            flush()
            let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            var code: [Substring] = []
            i += 1
            while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                code.append(lines[i])
                i += 1
            }
            blocks.append(MDBlock(.code(lang, code.joined(separator: "\n"))))
            // Closed: final once the closing line is complete.
            if i < lines.count { checkpoint(after: i) }
            i += 1
            continue
        }
        // A formula on lines of its own: \[ … \] or $$ … $$, opened on a line
        // by itself or whole on one line.
        if let (open, close) = [("\\[", "\\]"), ("$$", "$$")].first(where: { trimmed.hasPrefix($0.0) }),
           trimmed == open || (trimmed.hasSuffix(close) && trimmed.count > open.count + close.count) {
            flush()
            var body = ""
            var closed = false
            if trimmed != open {
                body = String(trimmed.dropFirst(open.count).dropLast(close.count))
                closed = true
            } else {
                var parts: [String] = []
                while i + 1 < lines.count {
                    i += 1
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasSuffix(close) { parts.append(String(t.dropLast(close.count))); closed = true; break }
                    parts.append(t)
                }
                body = parts.joined(separator: "\n")
            }
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { blocks.append(MDBlock(.math(body))) }
            // Still open while streaming: not final yet.
            if closed { checkpoint(after: i) }
            i += 1
            continue
        }
        if trimmed.isEmpty {
            flush()
        } else if let m = trimmed.firstMatch(of: #/^(#{1,6})\s+(.*)$/#) {
            flush()
            blocks.append(MDBlock(.heading(m.1.count, inlineMarkdown(String(m.2)))))
        } else if trimmed.firstMatch(of: #/^([-*_])(\s*\1){2,}$/#) != nil {
            flush()
            blocks.append(MDBlock(.rule))
        } else if trimmed.hasPrefix("|") {
            if !para.isEmpty || !list.isEmpty || !quote.isEmpty { flush() }
            let cells = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                .components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            if !cells.allSatisfy({ $0.firstMatch(of: #/^:?-+:?$/#) != nil }) { table.append(cells) }
        } else if let m = line.firstMatch(of: #/^(\s*)([-*+]|\d+[.)])\s+(.*)$/#) {
            if !para.isEmpty || !quote.isEmpty || !table.isEmpty { flush() }
            let marker = ["-", "*", "+"].contains(String(m.2)) ? "•" : String(m.2)
            list.append((marker, String(m.3), m.1.count / 2))
        } else if trimmed.hasPrefix(">") {
            if !para.isEmpty || !list.isEmpty || !table.isEmpty { flush() }
            quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
        } else if !list.isEmpty, line.hasPrefix("  ") {
            list[list.count - 1].text += " " + trimmed
        } else {
            if !list.isEmpty || !quote.isEmpty || !table.isEmpty { flush() }
            para.append(line)
        }
        checkpoint(after: i)
        i += 1
    }
    flush()
    return ParseResult(blocks: blocks, stableCount: stableCount, stableEnd: stableEnd)
}

// A message's parsed text, updated as it grows.
final class MarkdownDocument {
    private(set) var text = ""
    private(set) var blocks: [MDBlock] = []
    // Blocks that can't change while the text only grows, and where they end.
    private var stable: [MDBlock] = []
    private var stableEnd = 0

    init() {}

    init(text: String, parsed: ParseResult) {
        self.text = text
        blocks = parsed.blocks
        stable = Array(parsed.blocks.prefix(parsed.stableCount))
        stableEnd = parsed.stableEnd
    }

    func update(_ new: String) -> [MDBlock] {
        if new == text { return blocks }
        // Still the same up to the checkpoint (the text grew): parse the rest.
        // Anything else (an edit): parse it all.
        if stableEnd > 0, !(new.utf8.count >= stableEnd && new.utf8.prefix(stableEnd).elementsEqual(text.utf8.prefix(stableEnd))) {
            stable = []
            stableEnd = 0
        }
        let utf8 = new.utf8
        let from = utf8.index(utf8.startIndex, offsetBy: stableEnd)
        let rest = parseBlocks(new[from...])
        blocks = stable + rest.blocks
        stable += rest.blocks.prefix(rest.stableCount)
        stableEnd += rest.stableEnd
        text = new
        return blocks
    }
}

// Parsed messages, by id. Bounded; emptied when the window hides.
final class MarkdownCache {
    static let shared = MarkdownCache()
    private var docs: [UUID: MarkdownDocument] = [:]
    private var order: [UUID] = []
    private let limit = 600

    func blocks(for id: UUID, text: String) -> [MDBlock] {
        if let doc = docs[id] { return doc.update(text) }
        let doc = MarkdownDocument()
        insert(id, doc)
        return doc.update(text)
    }

    func contains(_ id: UUID) -> Bool { docs[id] != nil }

    func insert(_ id: UUID, _ doc: MarkdownDocument) {
        if docs[id] == nil { order.append(id) }
        docs[id] = doc
        if order.count > limit {
            let drop = order.prefix(order.count - limit)
            for old in drop { docs[old] = nil }
            order.removeFirst(drop.count)
        }
    }

    func removeAll() {
        docs = [:]
        order = []
    }

    // Parses a chat's latest answers off the main thread, newest first, so
    // they're ready before they scroll into view. At most 200: well under the
    // cache's limit, so they never push out the ones on screen.
    func prepare(_ messages: [Message]) {
        let latest = messages.reversed().filter { $0.role == .assistant && !$0.text.isEmpty }.prefix(200)
        let todo: [(UUID, String)] = latest.filter { !contains($0.id) }.map { ($0.id, $0.text) }
        guard !todo.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            // In batches, so the first answers are ready soon.
            for batch in stride(from: 0, to: todo.count, by: 20).map({ Array(todo[$0..<min($0 + 20, todo.count)]) }) {
                let parsed = batch.map { ($0.0, $0.1, parseBlocks(Substring($0.1))) }
                DispatchQueue.main.async {
                    for (id, text, result) in parsed where !self.contains(id) {
                        self.insert(id, MarkdownDocument(text: text, parsed: result))
                    }
                }
            }
        }
    }
}
