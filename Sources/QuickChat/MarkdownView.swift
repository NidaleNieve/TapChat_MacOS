import AppKit
import SwiftUI

// A small Markdown renderer: paragraphs, headings, lists, quotes, code blocks
// and tables, with inline styles from AttributedString.
struct MarkdownView: View {
    let text: String
    // While an answer streams in: how many of the newest characters are still fading in.
    var fadeTail = 0

    var body: some View {
        let blocks = parseBlocks(text)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, block in
                view(for: block, fading: fadeTail > 0 && i == blocks.count - 1)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MDBlock, fading: Bool) -> some View {
        switch block {
        case .paragraph(let s):
            Text(inline(s, fade: fading)).font(.system(size: 14)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let s):
            Text(inline(s, fade: fading))
                .font(.system(size: level == 1 ? 19 : level == 2 ? 17 : 15, weight: .semibold))
                .padding(.top, 4)
        case .list(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { n, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.marker).font(.system(size: 14)).foregroundStyle(.secondary)
                            .frame(minWidth: 14, alignment: .trailing)
                        Text(inline(item.text, fade: fading && n == items.count - 1)).font(.system(size: 14)).lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.indent) * 16)
                }
            }
        case .quote(let s):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(.secondary.opacity(0.5)).frame(width: 3)
                Text(inline(s, fade: fading)).font(.system(size: 14)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .code(let lang, let code):
            CodeBlock(language: lang, code: code)
        case .table(let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(inline(cell)).font(.system(size: 13, weight: r == 0 ? .semibold : .regular))
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

    private func inline(_ s: String, fade: Bool = false) -> AttributedString {
        var a = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
        guard fade else { return a }
        // The last ~30 characters ramp up from transparent; as the text grows
        // each character brightens over a few frames: a soft fade-in.
        let n = min(fadeTail, a.characters.count)
        guard n > 0 else { return a }
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

enum MDBlock {
    case paragraph(String)
    case heading(Int, String)
    case list([MDListItem])
    case quote(String)
    case code(String, String)
    case table([[String]])
    case rule
}

struct MDListItem {
    var marker: String
    var text: String
    var indent: Int
}

func parseBlocks(_ text: String) -> [MDBlock] {
    var blocks: [MDBlock] = []
    var para: [String] = []
    var list: [MDListItem] = []
    var quote: [String] = []
    var table: [[String]] = []
    let lines = text.components(separatedBy: "\n")
    var i = 0

    func flush() {
        if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: "\n"))); para = [] }
        if !list.isEmpty { blocks.append(.list(list)); list = [] }
        if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
        if !table.isEmpty { blocks.append(.table(table)); table = [] }
    }

    while i < lines.count {
        let line = lines[i]
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") {
            flush()
            let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            var code: [String] = []
            i += 1
            while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                code.append(lines[i])
                i += 1
            }
            blocks.append(.code(lang, code.joined(separator: "\n")))
            i += 1
            continue
        }
        if trimmed.isEmpty {
            flush()
        } else if let m = trimmed.firstMatch(of: #/^(#{1,6})\s+(.*)$/#) {
            flush()
            blocks.append(.heading(m.1.count, String(m.2)))
        } else if trimmed.firstMatch(of: #/^([-*_])(\s*\1){2,}$/#) != nil {
            flush()
            blocks.append(.rule)
        } else if trimmed.hasPrefix("|") {
            if !para.isEmpty || !list.isEmpty || !quote.isEmpty { flush() }
            let cells = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                .components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            if !cells.allSatisfy({ $0.firstMatch(of: #/^:?-+:?$/#) != nil }) { table.append(cells) }
        } else if let m = line.firstMatch(of: #/^(\s*)([-*+]|\d+[.)])\s+(.*)$/#) {
            if !para.isEmpty || !quote.isEmpty || !table.isEmpty { flush() }
            let marker = ["-", "*", "+"].contains(String(m.2)) ? "•" : String(m.2)
            list.append(MDListItem(marker: marker, text: String(m.3), indent: m.1.count / 2))
        } else if trimmed.hasPrefix(">") {
            if !para.isEmpty || !list.isEmpty || !table.isEmpty { flush() }
            quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
        } else if !list.isEmpty, line.hasPrefix("  ") {
            list[list.count - 1].text += " " + trimmed
        } else {
            if !list.isEmpty || !quote.isEmpty || !table.isEmpty { flush() }
            para.append(line)
        }
        i += 1
    }
    flush()
    return blocks
}
