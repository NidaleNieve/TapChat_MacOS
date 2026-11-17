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

    // The card: its name and, below, its kind and size (or "Writing…"),
    // indented past the icon and clear of the buttons. MessageTextView draws
    // the box, the icon and the buttons.
    func cardText() -> NSAttributedString {
        let out = NSMutableAttributedString()
        let top = NSMutableParagraphStyle()
        top.paragraphSpacingBefore = 12
        top.paragraphSpacing = 1
        top.firstLineHeadIndent = 54
        top.headIndent = 54
        top.tailIndent = -150
        top.lineBreakMode = .byTruncatingMiddle
        out.append(NSAttributedString(string: name + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor, .paragraphStyle: top, .tapChatFile: self,
        ]))
        let bottom = top.mutableCopy() as! NSMutableParagraphStyle
        bottom.paragraphSpacingBefore = 0
        bottom.paragraphSpacing = 12 + 10
        let size = ByteCountFormatter.string(fromByteCount: Int64(content.utf8.count), countStyle: .file)
        let detail = done ? (Self.converted.contains(ext) ? kind : "\(kind) · \(size)") : "Writing…"
        out.append(NSAttributedString(string: detail, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: bottom, .tapChatFile: self,
        ]))
        return out
    }

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

    func open() {
        guard canOpen else { return }
        let dir = Paths.temporary.appendingPathComponent("files/\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        if write(to: url) { NSWorkspace.shared.open(url) } else { NSSound.beep() }
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
