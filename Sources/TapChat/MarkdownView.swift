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
// - Each block is its own view, compared by identity: blocks that didn't
//   change aren't evaluated, laid out or drawn again.
struct MarkdownView: View {
    let text: String
    // The message the text belongs to: its parse is kept and reused. nil: parsed each time (short texts).
    var id: UUID?
    // While an answer streams in: how many of the newest characters are still fading in.
    var fadeTail = 0

    var body: some View {
        let blocks = id.map { MarkdownCache.shared.blocks(for: $0, text: text) } ?? parseBlocks(Substring(text)).blocks
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks.indices, id: \.self) { i in
                BlockView(block: blocks[i], fadeTail: i == blocks.count - 1 ? fadeTail : 0).equatable()
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

    static func == (a: BlockView, b: BlockView) -> Bool { a.block === b.block && a.fadeTail == b.fadeTail }

    var body: some View {
        switch block.kind {
        case .paragraph(let s):
            Text(faded(s)).font(.system(size: 14)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let s):
            Text(faded(s))
                .font(.system(size: level == 1 ? 19 : level == 2 ? 17 : 15, weight: .semibold))
                .padding(.top, 4)
        case .list(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(items.indices, id: \.self) { n in
                    let item = items[n]
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.marker).font(.system(size: 14)).foregroundStyle(.secondary)
                            .frame(minWidth: 14, alignment: .trailing)
                        Text(n == items.count - 1 ? faded(item.text) : item.text).font(.system(size: 14)).lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.indent) * 16)
                }
            }
        case .quote(let s):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(.secondary.opacity(0.5)).frame(width: 3)
                Text(faded(s)).font(.system(size: 14)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .code(let lang, let code):
            CodeBlock(language: lang, code: code)
        case .table(let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    ForEach(rows.indices, id: \.self) { r in
                        GridRow {
                            ForEach(rows[r].indices, id: \.self) { c in
                                Text(rows[r][c]).font(.system(size: 13, weight: r == 0 ? .semibold : .regular))
                            }
                        }
                        if r == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                    }
                }
                .padding(.vertical, 4)
            }
        case .rule:
            Divider()
        }
    }

    // The last ~30 characters ramp up from transparent; as the text grows
    // each character brightens over a few frames: a soft fade-in.
    private func faded(_ s: AttributedString) -> AttributedString {
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
    }
    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }
}

struct MDListItem {
    var marker: String
    var text: AttributedString
    var indent: Int
}

func inlineMarkdown(_ s: String) -> AttributedString {
    (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
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
