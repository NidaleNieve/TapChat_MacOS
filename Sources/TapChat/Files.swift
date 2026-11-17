import AppKit
import UniformTypeIdentifiers

// A file the model wrote in its answer (a ```file:name block), shown as a
// card. Nothing reaches the disk until the user clicks: Open writes a copy to
// TapChat's temporary folder, Save… writes where the user picks. Both copies
// are quarantined, so macOS checks scripts and the like before they run, and
// Open is offered only for documents (never scripts, apps or shortcuts).
final class FileInfo: NSObject {
    let name: String
    let content: String
    let done: Bool

    init(name: String, content: String, done: Bool) {
        self.name = FileInfo.safeName(name)
        self.content = content
        self.done = done
    }

    // A plain file name: no folders, no leading dots, not too long.
    static func safeName(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: CharacterSet(charactersIn: "`\"' "))
        s = (s as NSString).lastPathComponent
        s = s.replacingOccurrences(of: ":", with: "-")
        s = String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        while s.hasPrefix(".") { s.removeFirst() }
        if s.count > 120 {
            let ext = (s as NSString).pathExtension
            s = String(s.prefix(100)) + (ext.isEmpty ? "" : "." + ext)
        }
        return s.isEmpty ? "file.txt" : s
    }

    var ext: String { (name as NSString).pathExtension.lowercased() }

    // Written as HTML by the model, converted here.
    private static let converted: Set<String> = ["docx", "pdf", "rtf", "odt"]
    // Documents that only open in a viewer or editor.
    private static let openable: Set<String> = converted.union([
        "txt", "md", "markdown", "csv", "tsv", "json", "xml", "yaml", "yml", "html", "htm", "svg",
        "ics", "vcf", "log", "tex", "css",
    ])

    var canOpen: Bool { Self.openable.contains(ext) }
    // A file of this extension only opens in a viewer or editor (or, a zip, unpacks).
    static func safeToOpen(_ ext: String) -> Bool { openable.contains(ext.lowercased()) || ext.lowercased() == "zip" }

    var icon: NSImage {
        NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
    }

    var kind: String {
        let names = ["docx": "Word document", "pdf": "PDF document", "rtf": "Rich text document", "odt": "OpenDocument text",
                     "md": "Markdown", "markdown": "Markdown", "csv": "Spreadsheet (CSV)", "txt": "Text"]
        if let n = names[ext] { return n }
        if let t = UTType(filenameExtension: ext), let d = t.localizedDescription, !t.isDynamic, d.count <= 28 { return d.prefix(1).uppercased() + d.dropFirst() }
        return ext.isEmpty ? "File" : ext.uppercased() + " file"
    }

    // The card's text: only its name, so that's all a selection takes.
    // MessageTextView draws the box, the icon, the line below the name
    // (`detail`) and the buttons, in the room this leaves.
    static let detailHeight: CGFloat = 16
    static let padding: CGFloat = 12

    func cardText() -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = Self.padding
        p.paragraphSpacing = Self.detailHeight + Self.padding + 10
        p.firstLineHeadIndent = 54
        p.headIndent = 54
        p.tailIndent = -150
        p.lineBreakMode = .byTruncatingMiddle
        return NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor, .paragraphStyle: p, .tapChatFile: self,
        ])
    }

    var detail: String {
        guard done else { return "Writing…" }
        if Self.converted.contains(ext) { return kind }
        return "\(kind) · " + ByteCountFormatter.string(fromByteCount: Int64(content.utf8.count), countStyle: .file)
    }

    // Plain text the model wrote as is (not converted): its contents can be copied as text.
    var isText: Bool { !Self.converted.contains(ext) }

    // MARK: Contents

    func data() -> Data? {
        guard Self.converted.contains(ext) else { return content.data(using: .utf8) }
        guard let doc = attributed() else { return nil }
        let range = NSRange(location: 0, length: doc.length)
        switch ext {
        case "docx": return try? doc.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        case "odt": return try? doc.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.openDocument])
        case "rtf": return try? doc.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        default: return pdf(doc)
        }
    }

    // The model's HTML (or plain text, as paragraphs) as styled text.
    private func attributed() -> NSAttributedString? {
        var html = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !html.contains("<") {
            html = html.components(separatedBy: "\n\n").map {
                "<p>" + $0.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: "\n", with: "<br>") + "</p>"
            }.joined()
        }
        if !html.lowercased().contains("<style") {
            html = "<style>body{font-family:-apple-system,'Helvetica Neue',sans-serif;font-size:12pt;line-height:1.4}"
                + "table{border-collapse:collapse}td,th{border:1px solid #bbb;padding:4px 8px}</style>" + html
        }
        guard let data = html.data(using: .utf8) else { return nil }
        return try? NSAttributedString(data: data, options: [
            .documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue,
        ], documentAttributes: nil)
    }

    // US Letter pages with 1 inch margins: the text flows through one
    // container per page, each drawn into its own PDF page.
    private func pdf(_ doc: NSAttributedString) -> Data? {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792), margin: CGFloat = 72
        let storage = NSTextStorage(attributedString: doc)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        var containers: [NSTextContainer] = []
        repeat {
            let c = NSTextContainer(size: NSSize(width: page.width - 2 * margin, height: page.height - 2 * margin))
            c.lineFragmentPadding = 0
            layout.addTextContainer(c)
            containers.append(c)
            layout.ensureLayout(for: c)
        } while NSMaxRange(layout.glyphRange(for: containers.last!)) < layout.numberOfGlyphs && containers.count < 500
        let out = NSMutableData()
        var box = page
        guard let consumer = CGDataConsumer(data: out as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        let saved = NSGraphicsContext.current
        for c in containers {
            ctx.beginPDFPage(nil)
            ctx.translateBy(x: 0, y: page.height)
            ctx.scaleBy(x: 1, y: -1)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            let glyphs = layout.glyphRange(for: c)
            let origin = NSPoint(x: margin, y: margin)
            layout.drawBackground(forGlyphRange: glyphs, at: origin)
            layout.drawGlyphs(forGlyphRange: glyphs, at: origin)
            ctx.endPDFPage()
        }
        NSGraphicsContext.current = saved
        ctx.closePDF()
        return out as Data
    }

    // MARK: Actions

    private func write(to url: URL) -> Bool {
        guard let data = data() else { return false }
        do { try data.write(to: url, options: .atomic) } catch { return false }
        var u = url
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineAgentNameKey as String: "TapChat",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
        ]
        try? u.setResourceValues(values)
        return true
    }

    // A copy in TapChat's temporary folder (emptied at launch).
    private func temporaryCopy() -> URL? {
        let dir = Paths.temporary.appendingPathComponent("files/\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        return write(to: url) ? url : nil
    }

    func open() {
        guard canOpen else { return }
        if let url = temporaryCopy() { NSWorkspace.shared.open(url) } else { NSSound.beep() }
    }

    // The file itself, as a user's attachment copies: pastes into Finder, Mail, chats.
    func copyFile() -> Bool {
        guard let url = temporaryCopy() else { NSSound.beep(); return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.writeObjects([url as NSURL])
    }

    func copy() -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(content, forType: .string)
    }

    func save(from window: NSWindow?) -> Bool {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.canCreateDirectories = true
        panel.level = .floating + 1
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        if write(to: url) { return true }
        NSSound.beep()
        return false
    }
}

// Files an answer made or changed with its tools (file editing): the paths
// it gives that exist and were changed since it began. Worked out once per
// answer text (a few file checks), not on every redraw.
enum MadeFiles {
    // The answer as shown: without its <file> tags (shown as cards instead),
    // a half-written one at the end, or lines that are only a path into
    // TapChat's work folder (meaningless to the user; the card has it).
    static func clean(_ text: String) -> String {
        guard text.contains("<file") || text.contains(Paths.work.path) || text.contains("TapChat/work") else { return text }
        var t = text.replacingOccurrences(of: #"[ \t]*<file>[^<]*</file>[ \t]*\n?"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"<file>[^<]*$|<fil?e?$"#, with: "", options: .regularExpression)
        let work = Paths.work.path
        let lines = t.components(separatedBy: "\n").filter { line in
            let bare = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t`*_"))
            let expanded = bare.hasPrefix("~/") ? NSHomeDirectory() + bare.dropFirst(1) : bare
            return !(expanded.hasPrefix(work + "/") && FileManager.default.fileExists(atPath: expanded))
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static var cache: [UUID: (Int, [URL])] = [:]

    static func of(_ m: Message) -> [URL] {
        guard m.role == .assistant, m.text.contains("/") else { return [] }
        // Old answers without a start time: only the files they named in tags.
        let since = m.startedAt ?? .distantFuture
        let key = m.text.hashValue
        if let hit = cache[m.id], hit.0 == key { return hit.1 }
        let found = find(m.text, since: since)
        cache[m.id] = (key, found)
        return found
    }

    static func find(_ text: String, since: Date) -> [URL] {
        // <file> tags (named on purpose: shown whenever they exist), then in
        // backticks, in bold, link targets, and bare paths.
        var tagged = Set<String>()
        if let re = try? NSRegularExpression(pattern: #"<file>\s*([^<]+?)\s*</file>"#) {
            let ns = text as NSString
            for match in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                var p = ns.substring(with: match.range(at: 1))
                if p.hasPrefix("~/") { p = NSHomeDirectory() + p.dropFirst(1) }
                tagged.insert(p)
            }
        }
        let patterns = [#"<file>\s*([^<]+?)\s*</file>"#, #"`([^`\n]+)`"#, #"\*\*([^*\n]+)\*\*"#, #"\]\(([^)\s]+)\)"#, #"(?:^|\s)((?:~|/)[^\s`*]+)"#]
        var candidates: [String] = []
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            let ns = text as NSString
            for match in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) where match.numberOfRanges > 1 {
                candidates.append(ns.substring(with: match.range(at: 1)))
            }
        }
        var seen = Set<String>(), out: [URL] = []
        let fm = FileManager.default
        for raw in candidates {
            var s = raw.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("file://") { s = URL(string: s)?.path ?? s }
            s = s.removingPercentEncoding ?? s
            while let last = s.last, ".,:;)!?".contains(last) { s.removeLast() }
            if s.hasPrefix("~/") { s = NSHomeDirectory() + s.dropFirst(1) }
            guard s.hasPrefix("/"), !seen.contains(s) else { continue }
            seen.insert(s)
            var dir: ObjCBool = false
            guard fm.fileExists(atPath: s, isDirectory: &dir), !dir.boolValue else { continue }
            if !tagged.contains(s) {
                guard let changed = (try? fm.attributesOfItem(atPath: s))?[.modificationDate] as? Date,
                      changed >= since.addingTimeInterval(-2) else { continue }
            }
            out.append(URL(fileURLWithPath: s))
            if out.count == 8 { break }
        }
        return out
    }
}
